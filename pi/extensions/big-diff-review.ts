import { spawn, execFile } from "node:child_process";
import { createHash, randomBytes, randomUUID } from "node:crypto";
import { mkdtemp, mkdir, open, readFile, realpath, rename, rm, stat, readdir } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { dirname, join, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { TextDecoder } from "node:util";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const execFileAsync = promisify(execFile);
const PROTOCOL_VERSION = 1;
const MAX_RESULT_BYTES = 1024 * 1024;
const MAX_REVIEWS = 500;
const HANDOFF_PREFIX = "big-diff-review-";
const RECEIPT_TYPE = "big-diff-review-receipt";

interface Request {
	protocolVersion: 1;
	requestId: string;
	token: string;
	repoRoot: string;
	piSessionId: string;
	piSessionFile: string | null;
	pluginRoot: string;
	resultPath: string;
	reviewStatePath: string;
	targetRef: string;
	targetDescription: string;
	startedAt: number;
}

interface ResultReview { id: string; revision: number }
interface ReviewResult {
	protocolVersion: number;
	type: string;
	requestId: string;
	token: string;
	repoRoot: string;
	reviewCount: number;
	reviews: ResultReview[];
	markdown: string;
}

function isInside(path: string, parent: string): boolean {
	const prefix = parent.endsWith(sep) ? parent : parent + sep;
	return path === parent || path.startsWith(prefix);
}

async function atomicJson(path: string, value: unknown, mode = 0o600): Promise<void> {
	await mkdir(dirname(path), { recursive: true, mode: 0o700 });
	const temporary = `${path}.tmp-${process.pid}-${randomBytes(6).toString("hex")}`;
	const handle = await open(temporary, "wx", mode);
	try {
		await handle.writeFile(JSON.stringify(value, null, 2) + "\n", "utf8");
		await handle.sync();
	} finally {
		await handle.close();
	}
	await rename(temporary, path);
}

function nvimStatePath(repoRoot: string): string {
	const app = process.env.NVIM_APPNAME || "nvim";
	const base = process.env.XDG_STATE_HOME || join(homedir(), ".local", "state");
	const digest = createHash("sha256").update(repoRoot).digest("hex");
	return join(base, app, "big-diff", "reviews", `${digest}.json`);
}

async function repositoryRoot(cwd: string): Promise<string> {
	const { stdout } = await execFileAsync("git", ["rev-parse", "--show-toplevel"], { cwd, encoding: "utf8" });
	return realpath(stdout.trim());
}

function parseTargetRef(args: string): string {
	const target = args.trim() || "HEAD";
	if (target.startsWith("-") || target.length > 200 || /[\s\0-\x1f\x7f]/.test(target)) {
		throw new Error("Expected a single Git branch or revision, for example /nvim-review main");
	}
	return target;
}

async function verifyTargetRef(repoRoot: string, target: string): Promise<void> {
	try {
		await execFileAsync("git", ["rev-parse", "--verify", "--quiet", "--end-of-options", `${target}^{commit}`], {
			cwd: repoRoot,
			encoding: "utf8",
		});
	} catch {
		throw new Error(`Git branch or revision does not exist: ${target}`);
	}
}

function escapeRuntimePath(path: string): string {
	if (/[\r\n]/.test(path)) throw new Error("Plugin path contains a newline");
	return path.replace(/\\/g, "\\\\").replace(/([ ,|])/g, "\\$1");
}

async function cleanupStaleHandoffs(): Promise<void> {
	let entries: string[] = [];
	try { entries = await readdir(tmpdir()); } catch { return; }
	const cutoff = Date.now() - 24 * 60 * 60 * 1000;
	await Promise.all(entries.filter((name) => name.startsWith(HANDOFF_PREFIX)).map(async (name) => {
		const path = join(tmpdir(), name);
		try { if ((await stat(path)).mtimeMs < cutoff) await rm(path, { recursive: true, force: true }); } catch { /* best effort */ }
	}));
}

async function readResult(path: string, request: Request): Promise<ReviewResult | null> {
	let bytes: Buffer;
	try { bytes = await readFile(path); } catch (error: any) {
		if (error?.code === "ENOENT") return null;
		throw error;
	}
	if (bytes.length > MAX_RESULT_BYTES) throw new Error("Neovim review result exceeds 1 MiB");
	let text: string;
	try { text = new TextDecoder("utf-8", { fatal: true }).decode(bytes); }
	catch { throw new Error("Neovim review result is not valid UTF-8"); }
	let value: any;
	try { value = JSON.parse(text); } catch { throw new Error("Neovim review result is not valid JSON"); }
	if (value?.protocolVersion !== PROTOCOL_VERSION || value?.type !== "submit-review") throw new Error("Unsupported review result protocol");
	if (value.requestId !== request.requestId || value.token !== request.token) throw new Error("Review result capability does not match this launch");
	if (value.repoRoot !== request.repoRoot) throw new Error("Review result repository does not match this launch");
	if (!Array.isArray(value.reviews) || !Number.isInteger(value.reviewCount) || value.reviewCount !== value.reviews.length) throw new Error("Invalid review count");
	if (value.reviewCount < 1 || value.reviewCount > MAX_REVIEWS) throw new Error("Review count is outside allowed limits");
	if (typeof value.markdown !== "string" || Buffer.byteLength(value.markdown, "utf8") > MAX_RESULT_BYTES) throw new Error("Invalid review Markdown");
	for (const review of value.reviews) {
		if (!review || typeof review.id !== "string" || review.id.length > 200 || !Number.isInteger(review.revision) || review.revision < 1) throw new Error("Invalid submitted review reference");
	}
	return value as ReviewResult;
}

function alreadyDelivered(ctx: any, requestId: string): boolean {
	return ctx.sessionManager.getEntries().some((entry: any) =>
		entry.type === "custom" && entry.customType === RECEIPT_TYPE && entry.data?.requestId === requestId && entry.data?.status === "accepted");
}

async function reconcileAcceptedReceipts(ctx: any, path: string, repoRoot: string): Promise<void> {
	for (const entry of ctx.sessionManager.getEntries()) {
		const data = entry.type === "custom" && entry.customType === RECEIPT_TYPE ? entry.data : undefined;
		if (data?.status !== "accepted" || data.repoRoot !== repoRoot || !Array.isArray(data.reviews)) continue;
		await updateDeliveryState(path, { requestId: data.requestId, reviews: data.reviews } as ReviewResult, "accepted");
	}
}

async function updateDeliveryState(path: string, result: ReviewResult, status: "accepted" | "unknown"): Promise<void> {
	let state: any;
	try { state = JSON.parse(await readFile(path, "utf8")); } catch { return; }
	if (!state || !Array.isArray(state.reviews)) return;
	if (status === "unknown") {
		state.delivery_unknown = { requestId: result.requestId, reviews: result.reviews, recordedAt: Date.now() };
	} else {
		const accepted = new Map(result.reviews.map((review) => [review.id, review.revision]));
		for (const review of state.reviews) {
			if (accepted.get(review.id) === review.revision) {
				review.status = "submitted";
				review.last_submission_id = result.requestId;
				review.updated_at = Date.now();
			}
		}
		if (state.delivery_unknown?.requestId === result.requestId) delete state.delivery_unknown;
	}
	state.updated_at = Date.now();
	await atomicJson(path, state);
}

function launchNeovim(executable: string, args: string[], cwd: string, env: NodeJS.ProcessEnv): Promise<{ code: number | null; signal: NodeJS.Signals | null }> {
	return new Promise((resolvePromise, reject) => {
		const child = spawn(executable, args, { cwd, env, stdio: "inherit" });
		child.once("error", reject);
		child.once("exit", (code, signal) => resolvePromise({ code, signal }));
	});
}

export default function (pi: ExtensionAPI) {
	pi.registerCommand("nvim-review", {
		description: "Review changes against a Git ref in Neovim (default: all uncommitted changes)",
		handler: async (args, ctx) => {
			if (ctx.mode !== "tui") {
				const message = "/nvim-review requires an interactive TUI terminal";
				ctx.ui.notify(message, "error");
				if (!ctx.hasUI) console.error(message);
				return;
			}

			await ctx.waitForIdle();
			await cleanupStaleHandoffs();
			let repoRoot: string;
			try { repoRoot = await repositoryRoot(ctx.cwd); }
			catch { ctx.ui.notify("The current directory is not inside a Git repository", "error"); return; }

			let targetRef: string;
			try {
				targetRef = parseTargetRef(args);
				await verifyTargetRef(repoRoot, targetRef);
			} catch (error) {
				ctx.ui.notify(error instanceof Error ? error.message : String(error), "error");
				return;
			}
			const targetDescription = targetRef === "HEAD"
				? "uncommitted changes (staged and unstaged) compared with HEAD"
				: `working tree compared with ${targetRef}`;

			const pluginRoot = await realpath(resolve(dirname(fileURLToPath(import.meta.url)), "../.."));
			const reviewStatePath = nvimStatePath(repoRoot);
			await reconcileAcceptedReceipts(ctx, reviewStatePath, repoRoot).catch(() => undefined);
			const handoffDir = await mkdtemp(join(tmpdir(), HANDOFF_PREFIX));
			const requestPath = join(handoffDir, "request.json");
			const resultPath = join(handoffDir, "result.json");
			const request: Request = {
				protocolVersion: PROTOCOL_VERSION,
				requestId: randomUUID(),
				token: randomBytes(32).toString("hex"),
				repoRoot,
				piSessionId: ctx.sessionManager.getSessionId(),
				piSessionFile: ctx.sessionManager.getSessionFile() ?? null,
				pluginRoot,
				resultPath,
				reviewStatePath,
				targetRef,
				targetDescription,
				startedAt: Date.now(),
			};

			let attemptedResult: ReviewResult | null = null;
			let deliveryAttempted = false;
			try {
				if (!isInside(resultPath, handoffDir)) throw new Error("Invalid handoff result path");
				await atomicJson(requestPath, request);
				const executable = process.env.BIG_DIFF_NVIM || "nvim";
				const args = [
					"--cmd", `set runtimepath^=${escapeRuntimePath(pluginRoot)}`,
					"--cmd", "runtime plugin/big-diff-review.lua",
					"-c", "BigDiffReviewStart",
				];
				type LaunchOutcome = { code: number | null; signal: NodeJS.Signals | null; error?: string };
				const outcome = await ctx.ui.custom<LaunchOutcome>((tui, _theme, _kb, done) => {
					void (async () => {
						tui.stop();
						let result: LaunchOutcome;
						try {
							result = await launchNeovim(executable, args, repoRoot, { ...process.env, BIG_DIFF_REVIEW_HANDOFF: requestPath });
						} catch (error) {
							result = { code: null, signal: null, error: error instanceof Error ? error.message : String(error) };
						} finally {
							tui.start();
							tui.requestRender(true);
						}
						done(result!);
					})();
					return { render: () => [], invalidate: () => {} };
				});
				if (outcome.error) ctx.ui.notify(`Could not launch Neovim: ${outcome.error}`, "error");

				const result = await readResult(resultPath, request);
				if (!result) {
					if (outcome?.signal) ctx.ui.notify(`Neovim was terminated by ${outcome.signal}; review cancelled`, "warning");
					else if (outcome && outcome.code !== 0) ctx.ui.notify(`Neovim exited with code ${outcome.code}; review cancelled`, "warning");
					else ctx.ui.notify("Neovim review cancelled", "info");
					return;
				}
				if (alreadyDelivered(ctx, result.requestId)) {
					ctx.ui.notify("This review submission was already delivered", "warning");
					return;
				}

				attemptedResult = result;
				pi.appendEntry(RECEIPT_TYPE, {
					requestId: result.requestId, status: "sending", repoRoot, reviews: result.reviews, recordedAt: Date.now(),
				});
				deliveryAttempted = true;
				pi.sendUserMessage(result.markdown, { deliverAs: "followUp" });
				pi.appendEntry(RECEIPT_TYPE, {
					requestId: result.requestId,
					status: "accepted",
					repoRoot,
					reviews: result.reviews,
					acceptedAt: Date.now(),
				});
				await updateDeliveryState(request.reviewStatePath, result, "accepted");
			} catch (error) {
				if (deliveryAttempted && attemptedResult) {
					await updateDeliveryState(request.reviewStatePath, attemptedResult, "unknown").catch(() => undefined);
					ctx.ui.notify("Review delivery is unknown. Inspect the Pi transcript before retrying.", "error");
				} else {
					ctx.ui.notify(`Neovim review failed: ${error instanceof Error ? error.message : String(error)}`, "error");
				}
			} finally {
				await rm(handoffDir, { recursive: true, force: true }).catch(() => undefined);
			}
		},
	});
}
