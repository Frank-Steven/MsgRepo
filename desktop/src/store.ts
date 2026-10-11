import { appendFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import type { StructuredItem } from "./types.js";

/** 结果持久化：data/items.jsonl（每行一个 StructuredItem）+ data/hashes.json（已处理 contentHash）
 *  + data/hash_items.json（contentHash → 条目 id 列表，用于去重时找回既有结果）。 */
export class Store {
  private readonly itemsFile: string;
  private readonly hashesFile: string;
  private readonly hashItemsFile: string;
  private readonly hashes = new Set<string>();
  private readonly hashItems = new Map<string, string[]>();

  constructor(dataDir: string) {
    mkdirSync(dataDir, { recursive: true });
    this.itemsFile = path.join(dataDir, "items.jsonl");
    this.hashesFile = path.join(dataDir, "hashes.json");
    this.hashItemsFile = path.join(dataDir, "hash_items.json");
    if (existsSync(this.hashesFile)) {
      try {
        for (const h of JSON.parse(readFileSync(this.hashesFile, "utf8")) as string[]) {
          this.hashes.add(h);
        }
      } catch {
        // 损坏则视为空
      }
    }
    if (existsSync(this.hashItemsFile)) {
      try {
        const obj = JSON.parse(readFileSync(this.hashItemsFile, "utf8")) as Record<string, string[]>;
        for (const [h, ids] of Object.entries(obj)) this.hashItems.set(h, ids);
      } catch {
        // 损坏则视为空
      }
    }
  }

  hasHash(hash: string): boolean {
    return this.hashes.has(hash);
  }

  addHashes(hashes: string[]): void {
    for (const h of hashes) this.hashes.add(h);
    writeFileSync(this.hashesFile, JSON.stringify([...this.hashes]));
  }

  /** 记录 contentHash → 条目 id 映射（整体替换，重处理时指向新条目）。 */
  recordHashItems(pairs: Array<{ hash: string; itemId: string }>): void {
    for (const { hash, itemId } of pairs) this.hashItems.set(hash, [itemId]);
    writeFileSync(this.hashItemsFile, JSON.stringify(Object.fromEntries(this.hashItems)));
  }

  /** 按 contentHash 找回之前生成的结构化条目；无映射或条目已不存在时返回空数组。 */
  findItemsByHash(hash: string): StructuredItem[] {
    const ids = this.hashItems.get(hash);
    if (!ids || ids.length === 0) return [];
    const wanted = new Set(ids);
    return this.listItems().filter((item) => wanted.has(item.id));
  }

  appendItems(items: StructuredItem[]): void {
    if (items.length === 0) return;
    appendFileSync(this.itemsFile, items.map((i) => JSON.stringify(i)).join("\n") + "\n");
  }

  listItems(filter?: { category?: string; priority?: string }): StructuredItem[] {
    if (!existsSync(this.itemsFile)) return [];
    const items: StructuredItem[] = [];
    for (const line of readFileSync(this.itemsFile, "utf8").split("\n")) {
      if (!line.trim()) continue;
      try {
        const item = JSON.parse(line) as StructuredItem;
        if (filter?.category && item.category !== filter.category) continue;
        if (filter?.priority && item.priority !== filter.priority) continue;
        items.push(item);
      } catch {
        // 跳过坏行
      }
    }
    return items;
  }
}
