// at-anywhere.ts
// Claude Code 风格的 @ 引用增强：
//   - @.. / @../ 等点号路径：可直接浏览/补全上级目录内容，并提供 "上一级" 入口
//   - @/绝对路径、@~/home、@../相对上级：外部路径补全（目录不存在时自动回退到最近存在的上级）
//   - 其余（项目内 @name）：完全委托内置 provider，行为不变
//
// 安装：放到 ~/.pi/agent/extensions/at-anywhere.ts 后 /reload，或 pi -e at-anywhere.ts
// 用法：在输入框输入 @.. 、 @../ 、 @~/ 、 @/ 等，即可像 Claude Code 一样补全任意位置的路径

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import type {
	AutocompleteItem,
	AutocompleteProvider,
	AutocompleteSuggestions,
} from "@earendil-works/pi-tui";
import { readdirSync, statSync } from "node:fs";
import { basename, join, relative, resolve } from "node:path";
import { homedir } from "node:os";

const MAX_ITEMS = 30;
const MAX_DOT_DEPTH = 4; // @.. @../.. @../../.. 最多支持 4 级

// ---------- 小工具 ----------

function expandHome(p: string): string {
	const home = homedir();
	if (p === "~") return home;
	if (p.startsWith("~/")) return join(home, p.slice(2));
	return p;
}

/** 把绝对路径转成显示形式：home 下用 ~/ 开头，其余保持绝对 */
function toDisplayPath(abs: string): string {
	const home = homedir();
	if (abs === home) return "~";
	if (abs.startsWith(home + "/")) return "~" + abs.slice(home.length);
	return abs;
}

/** 相对 cwd 的显示形式（../x/y），供 @.. 类路径使用 */
function toRelativeDisplay(abs: string, cwd: string): string {
	const rel = relative(cwd, abs);
	return rel === "" ? "." : rel;
}

/** 构造补全项的 value：含 @ 前缀；含空格或用户已用引号时用 @"..." 包裹 */
function buildCompletionValue(displayPath: string, isDir: boolean, quoted: boolean): string {
	const pathWithSlash = isDir ? displayPath + "/" : displayPath;
	const needsQuotes = quoted || pathWithSlash.includes(" ");
	return needsQuotes ? `@"${pathWithSlash}"` : `@${pathWithSlash}`;
}

interface DirEntry {
	name: string;
	isDir: boolean;
}

/** 列出目录内容并按查询过滤（前缀匹配优先），排除 .git */
function listDirectory(dir: string, query: string, limit = MAX_ITEMS): DirEntry[] {
	let entries;
	try {
		entries = readdirSync(dir, { withFileTypes: true });
	} catch {
		return [];
	}
	const q = query.toLowerCase();
	const scored: Array<{ name: string; isDir: boolean; score: number }> = [];
	for (const e of entries) {
		if (e.name === ".git") continue;
		const name = e.name;
		let score = 0;
		if (!q) score = 1;
		else if (name.toLowerCase().startsWith(q)) score = 3;
		else if (name.toLowerCase().includes(q)) score = 2;
		else continue;
		scored.push({ name, isDir: e.isDirectory(), score });
	}
	scored.sort(
		(a, b) =>
			b.score - a.score ||
			(b.isDir ? 1 : 0) - (a.isDir ? 1 : 0) ||
			a.name.localeCompare(b.name),
	);
	return scored.slice(0, limit).map(({ name, isDir }) => ({ name, isDir }));
}

/** 目录不存在时逐级回退到最近存在的上级（最多 10 级） */
function findExistingDir(dir: string): string | null {
	let cur = dir;
	for (let i = 0; i < 10; i++) {
		try {
			if (statSync(cur).isDirectory()) return cur;
		} catch {
			// 不存在，继续向上
		}
		const parent = resolve(cur, "..");
		if (parent === cur) return null;
		cur = parent;
	}
	return null;
}

/** 解析光标前的 @ 前缀。返回替换前缀、@ 后原始路径、是否处于引号模式 */
function parseAtToken(textBeforeCursor: string): { prefix: string; raw: string; quoted: boolean } | null {
	const m = textBeforeCursor.match(/(?:^|[\s])@(?:"([^"]*)"?|([^\s]*))$/);
	if (!m) return null;
	const quoted = m[1] !== undefined;
	const raw = quoted ? (m[1] ?? "") : (m[2] ?? "");
	const prefix = m[0].trimStart();
	return { prefix, raw, quoted };
}

/** 判断是否为“外部路径”（需要接管补全） */
function isOutsidePath(raw: string): boolean {
	return (
		raw === ".." ||
		raw.startsWith("../") ||
		raw.startsWith("/") ||
		raw.startsWith("~/") ||
		raw === "~" ||
		/^\.{2,4}(?:\/\.{2,4})*\/?$/.test(raw)
	);
}

/** 解析纯点号串的上级级数：每个 ".." 段 = 1 级（".."→1，"../.."→2） */
function dotUpLevels(raw: string): number {
	return raw.split("/").filter((s) => s.length > 0).length;
}

/** 根据外部路径 raw 解析出：要列出的目录、查询串、条目显示前缀（含目录尾斜杠） */
function resolveOutside(raw: string, cwd: string): {
	baseAbs: string;
	query: string;
	displayPrefix: string;
	kind: "dots" | "relative" | "absolute" | "home";
} | null {
	// 纯点号：.. / ../ / ../../ 等（`.` 单独作为 cwd 内委托）
	const dots = raw.match(/^\.{2,4}(?:\/\.{2,4})*\/?$/);
	if (dots) {
		const levels = dotUpLevels(raw);
		const baseAbs = resolve(cwd, Array(levels).fill("..").join("/"));
		const displayPrefix = toRelativeDisplay(baseAbs, cwd) + "/";
		return { baseAbs, query: "", displayPrefix, kind: "dots" };
	}

	const slashIndex = raw.lastIndexOf("/");
	const dirPart = slashIndex === -1 ? "" : raw.slice(0, slashIndex + 1);
	const namePart = slashIndex === -1 ? raw : raw.slice(slashIndex + 1);

	if (dirPart.startsWith("/")) {
		// 绝对路径 /usr/local/li
		return { baseAbs: dirPart, query: namePart, displayPrefix: dirPart, kind: "absolute" };
	}
	if (dirPart.startsWith("~/")) {
		// home 路径 ~/Doc
		const home = homedir();
		return {
			baseAbs: expandHome(dirPart),
			query: namePart,
			displayPrefix: "~/" + dirPart.slice(2),
			kind: "home",
		};
	}
	// ../src/ma 这类相对上级
	const baseAbs = resolve(cwd, dirPart);
	return {
		baseAbs,
		query: namePart,
		displayPrefix: toRelativeDisplay(resolve(cwd, dirPart), cwd) + "/",
		kind: "relative",
	};
}

/** 把目录条目组装成补全项（value 完整可插入，格式与内置 provider 一致） */
function buildItems(
	entries: DirEntry[],
	displayPrefix: string,
	quoted: boolean,
	prepend: AutocompleteItem[] = [],
): AutocompleteItem[] {
	const items: AutocompleteItem[] = [...prepend];
	for (const { name, isDir } of entries) {
		const displayPath = displayPrefix + name;
		const value = buildCompletionValue(displayPath, isDir, quoted);
		items.push({
			value,
			label: name + (isDir ? "/" : ""),
			description: displayPath + (isDir ? "/" : ""),
		});
	}
	return items;
}

// ---------- provider ----------

function createAtAnywhereProvider(current: AutocompleteProvider, cwd: () => string): AutocompleteProvider {
	return {
		async getSuggestions(
			lines,
			cursorLine,
			cursorCol,
			options,
		): Promise<AutocompleteSuggestions | null> {
			const textBeforeCursor = (lines[cursorLine] ?? "").slice(0, cursorCol);
			const parsed = parseAtToken(textBeforeCursor);
			if (!parsed || !isOutsidePath(parsed.raw)) {
				// 项目内路径（@name、@./x）或非 @ 输入 → 内置行为
				return current.getSuggestions(lines, cursorLine, cursorCol, options);
			}
			if (options.signal.aborted) return null;

			const { prefix, raw, quoted } = parsed;
			const resolved = resolveOutside(raw, cwd());
			if (!resolved) return current.getSuggestions(lines, cursorLine, cursorCol, options);

			const searchBase = findExistingDir(resolved.baseAbs);
			if (!searchBase) {
				// 完全不存在（如 /nonexistent）→ 只给上级入口
				return {
					prefix,
					items: buildItems([], resolved.displayPrefix, quoted, [
						{
							value: `@${resolved.displayPrefix}`,
							label: resolved.displayPrefix,
							description: resolved.displayPrefix,
						},
					]),
				};
			}

			let entries = listDirectory(searchBase, resolved.query);

			// 纯点号模式：提供"再上一级"入口，让用户可以逐级跳出去
			let prepend: AutocompleteItem[] = [];
			if (resolved.kind === "dots") {
				const parent = findExistingDir(resolve(searchBase, ".."));
				if (parent && parent !== searchBase) {
					const parentDisplay = toRelativeDisplay(parent, cwd());
					prepend.push({
						value: `@${parentDisplay}/`,
						label: `../`,
						description: parentDisplay + "/",
					});
				}
			}

			// 目录存在但搜索目录比用户输入的路径更深（回退情形）：显示入口即可
			if (resolved.baseAbs !== searchBase) {
				// 用户输入的目标目录不存在：把回退到的目录入口放在最前
				const fallbackDisplay =
					resolved.kind === "absolute" || resolved.kind === "home"
						? toDisplayPath(searchBase)
						: toRelativeDisplay(searchBase, cwd());
				prepend = [
					{
						value: `@${fallbackDisplay}/`,
						label: basename(searchBase) + "/",
						description: fallbackDisplay + "/",
					},
					...prepend,
				];
			}

			const items = buildItems(entries, resolved.displayPrefix, quoted, prepend);
			if (items.length === 0) return null;
			return { prefix, items };
		},

		applyCompletion(lines, cursorLine, cursorCol, item, prefix) {
			return current.applyCompletion(lines, cursorLine, cursorCol, item, prefix);
		},

		shouldTriggerFileCompletion(lines, cursorLine, cursorCol) {
			return current.shouldTriggerFileCompletion?.(lines, cursorLine, cursorCol) ?? true;
		},
	};
}

export default function (pi: ExtensionAPI): void {
	pi.on("session_start", (_event, ctx) => {
		const getCwd = () => ctx.cwd || process.cwd();
		ctx.ui?.addAutocompleteProvider((current) => createAtAnywhereProvider(current, getCwd));
	});
}

// 供测试与复用（不影响扩展加载）
export {
	parseAtToken,
	isOutsidePath,
	resolveOutside,
	buildItems,
	buildCompletionValue,
	listDirectory,
	findExistingDir,
	createAtAnywhereProvider,
};
