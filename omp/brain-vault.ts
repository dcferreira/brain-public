/**
 * brain-vault — the oh-my-pi wiring for the second brain.
 *
 * Replaces the two Claude Code shell hooks (`obsidian-session-start.sh` /
 * `obsidian-session-end.sh`) with the omp equivalents:
 *
 *   before_agent_start → inject top-of-mind + the latest session note + qmd hits for
 *                      the current project (scope-aware, via brain-search) as a hidden custom message, once per
 *                      session, ahead of the first turn. Also states the session id,
 *                      which `/skill:brain-persist` records in `session_ids`.
 *   session_shutdown → detached `qmd update` plus `qmd --index private update` (reindex only).
 *
 * Wired in through `extensions:` in `~/.omp/agent/config.yml`; see the repo SETUP.md.
 * Env overrides: BRAIN_VAULT, BRAIN_QMD, BRAIN_BIN (dir holding brain-search), BRAIN_SCOPE
 * (shared|private|all; unset/unknown = shared), BRAIN_PROJECT.
 */
import { existsSync } from "node:fs";
import { readdir, readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";

const VAULT = process.env.BRAIN_VAULT ?? join(homedir(), "Obsidian", "vault");
const QMD = process.env.BRAIN_QMD ?? join(homedir(), ".nodenv", "shims", "qmd");
/** The extension is loaded from the repo by absolute path, so `<repo>/bin` sits two levels up. */
const BIN = process.env.BRAIN_BIN ?? join(dirname(fileURLToPath(import.meta.url)), "..", "bin");

/** cwd basenames whose search hits are noise (the vault itself, and the home dir). */
const SKIP_SEARCH: Record<string, true> = { vault: true, [basename(homedir())]: true };

type Scope = "shared" | "private" | "all";

/** Mirror of brain-scope `norm`: anything but private/all is shared (fail closed). */
function normScope(raw: string | undefined): Scope {
	const s = (raw ?? "").trim().toLowerCase();
	return s === "private" || s === "all" ? s : "shared";
}

/** Mirror of brain-scope `includes <scope> private`. */
function includesPrivate(scope: Scope): boolean {
	return scope === "private" || scope === "all";
}

async function readIfPresent(path: string): Promise<string | undefined> {
	try {
		return await readFile(path, "utf8");
	} catch {
		return undefined;
	}
}

/** Newest dated `*.md` across the given session dirs, by basename — ISO dates sort correctly. */
async function latestSessionNote(dirs: string[]): Promise<string | undefined> {
	const found: { name: string; path: string }[] = [];
	for (const dir of dirs) {
		let names: string[];
		try {
			names = await readdir(dir);
		} catch {
			continue;
		}
		for (const name of names) {
			if (name.endsWith(".md") && /^\d{4}-\d{2}-\d{2}/.test(name)) found.push({ name, path: join(dir, name) });
		}
	}
	found.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
	const newest = found.at(-1);
	return newest ? readIfPresent(newest.path) : undefined;
}

/** Resolve the qmd binary; undefined when not installed. */
function resolveQmd(): string | undefined {
	if (existsSync(QMD)) return QMD;
	return Bun.which("qmd") ?? undefined;
}

/** brain-search: `${BRAIN_BIN}/brain-search`, else on PATH; undefined when absent. */
function resolveBrainSearch(): string | undefined {
	const local = join(BIN, "brain-search");
	if (existsSync(local)) return local;
	return Bun.which("brain-search") ?? undefined;
}

/** Up to 3 scope-aware hits for the query, via brain-search. Skipped when it or qmd is missing. */
async function relatedNotes(query: string, scope: Scope, project: string): Promise<string | undefined> {
	const qmd = resolveQmd();
	const search = resolveBrainSearch();
	if (!qmd || !search) return undefined;
	try {
		const args = ["--scope", scope, "-n", "3"];
		if (project) args.push("--project", project);
		args.push(query);
		const proc = Bun.spawn([search, ...args], {
			env: { ...process.env, BRAIN_QMD: qmd, BUN_INSTALL: "" },
			stdin: "ignore",
			stdout: "pipe",
			stderr: "ignore",
		});
		const text = (await new Response(proc.stdout).text()).trim();
		await proc.exited;
		return text || undefined;
	} catch {
		return undefined;
	}
}

export async function buildContext(cwd: string, sessionId: string): Promise<string | undefined> {
	const scope = normScope(process.env.BRAIN_SCOPE);
	const project = process.env.BRAIN_PROJECT ?? "";
	const priv = includesPrivate(scope);
	// Id first, as in the Claude Code hook (a long context may be truncated to a preview).
	const sections: string[] = [`This session's id is ${sessionId} (harness: omp)`];

	const topOfMind = await readIfPresent(join(VAULT, "00-home", "top-of-mind.md"));
	// An oversized top-of-mind bloats every session: nudge towards brain-sweep.
	const tomBytes = topOfMind === undefined ? 0 : Buffer.byteLength(topOfMind);
	if (tomBytes > 40 * 1024)
		sections[0] += `\n⚠ top-of-mind.md is ${Math.floor(tomBytes / 1024)} KB — run brain-sweep (or brain-plan-day) to archive done items.`;
	if (topOfMind) sections.push("--- VAULT: TOP OF MIND ---\n" + topOfMind);

	if (priv) {
		const privateTom = await readIfPresent(join(VAULT, "private", "private.md"));
		if (privateTom) sections.push("--- VAULT: PRIVATE TOP OF MIND ---\n" + privateTom);
	}

	const sessionDirs = [join(VAULT, "sessions")];
	if (priv) sessionDirs.push(join(VAULT, "private", "sessions"));
	const latest = await latestSessionNote(sessionDirs);
	if (latest) sections.push("--- VAULT: LATEST SESSION ---\n" + latest);

	let query = project;
	if (!query) {
		query = basename(cwd);
		if (SKIP_SEARCH[query]) query = "";
	}
	if (query) {
		const hits = await relatedNotes(query, scope, project);
		if (hits) sections.push(`--- VAULT: RELATED NOTES (project: ${query}) ---\n` + hits);
	}

	const todayLoc = priv
		? "current (work and projects actions live in 00-home/top-of-mind.md, private ones in private/private.md)"
		: "in top-of-mind (00-home/top-of-mind.md) current";
	let scopeLine = `Vault scope for this session: ${scope}`;
	if (project) scopeLine += `, project: ${project}`;
	scopeLine += ". Private notes live under private/ and are only visible in private/all scope.";

	sections.push(
		[
			"--- END VAULT CONTEXT ---",
			`The knowledge vault is at ${VAULT} — read and write it with native file tools, search it with \`brain-search "<query>"\` (scope-aware; add \`--project <slug>\` to focus). Load and save session context with the brain-orient and brain-persist skills (\`/skill:brain-orient\`, \`/skill:brain-persist\`).`,
			`As you work, keep the Today list ${todayLoc}: when you start on something, mark the matching Today action in-progress ([/]) — or, if it isn't listed, add it under Today as a new [/] action — and mark it [x] when done. State briefly what you changed; never edit silently.`,
			scopeLine,
		].join("\n"),
	);

	return sections.join("\n\n");
}

export default function brainVault(pi: ExtensionAPI): void {
	// `before_agent_start` rather than `session_start`: the session-start handler is
	// raced by the launch prompt (a `nextTurn` message queued ~500ms in was too late
	// for the first turn and never delivered). Fires before each turn, so it is keyed
	// by session id to inject exactly once even if the factory is shared across
	// sessions in one process.
	const injected = new Set<string>();

	pi.on("before_agent_start", async (_event, ctx) => {
		try {
			const sessionId = ctx.sessionManager.getSessionId();
			if (injected.has(sessionId)) return;
			injected.add(sessionId);
			const context = await buildContext(ctx.cwd, sessionId);
			if (!context) return;
			return { message: { customType: "brain-vault-context", content: context, display: false } };
		} catch (error) {
			// Never fail a session because the vault is unreadable — but don't hide why.
			try {
				pi.logger?.warn(`brain-vault: context injection failed: ${String(error)}`);
			} catch {}
			return;
		}
	});

	pi.on("session_shutdown", () => {
		// Reindex only (shared index, then the private one). Detached so shutdown is never
		// blocked, and `.exited` is caught so a failed spawn cannot surface as a rejection.
		for (const args of [["update"], ["--index", "private", "update"]]) {
			try {
				const proc = Bun.spawn([QMD, ...args], {
					env: { ...process.env, BUN_INSTALL: "" },
					stdin: "ignore",
					stdout: "ignore",
					stderr: "ignore",
				});
				proc.unref();
				proc.exited.catch(() => {});
			} catch {
				// qmd not installed, or no private index — nothing to reindex.
			}
		}
	});
}
