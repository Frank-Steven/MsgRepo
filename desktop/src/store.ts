import { appendFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import type { StructuredItem } from "./types.js";

/** 结果持久化：data/items.jsonl（每行一个 StructuredItem）+ data/hashes.json（已处理 contentHash）。 */
export class Store {
  private readonly itemsFile: string;
  private readonly hashesFile: string;
  private readonly hashes = new Set<string>();

  constructor(dataDir: string) {
    mkdirSync(dataDir, { recursive: true });
    this.itemsFile = path.join(dataDir, "items.jsonl");
    this.hashesFile = path.join(dataDir, "hashes.json");
    if (existsSync(this.hashesFile)) {
      try {
        for (const h of JSON.parse(readFileSync(this.hashesFile, "utf8")) as string[]) {
          this.hashes.add(h);
        }
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
