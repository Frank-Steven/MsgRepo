import type { ProcessInputMessage } from "../types.js";

/**
 * 本地垃圾规则预过滤（v2.6.1 AI 省 Token 策略，宁漏勿错）：
 * 命中即在送模型前直接判 junk，不消耗 Token；结果 reason 标注「规则判定」。
 * 规则与 mobile/lib/services/junk_rules.dart 逐条一致（改任何一端必须同步另一端）。
 */

/** 营销/运营模板关键词：标题或正文命中任一即判垃圾。
 *  只收命中率极高的 boilerplate，避免误伤真人聊天（宁漏勿错）。 */
export const JUNK_KEYWORDS = [
  "退订",
  "回T退订",
  "TD退订",
  "限时秒杀",
  "秒杀价",
  "免费领取",
  "点击领取",
  "现金红包",
  "刷单兼职",
  "兼职日结",
  "低价开发票",
  "0元购",
];

/** 运营短信服务号（106 开头长号码）+ 含退订字样 → 垃圾。 */
function isServiceNumberWithOptOut(sender: string | undefined, text: string): boolean {
  if (!sender || !/^106\d{5,}$/.test(sender)) return false;
  return text.includes("退订");
}

/** 命中返回判定理由（标注「规则判定」），未命中返回 null。 */
export function junkRuleHit(msg: Pick<ProcessInputMessage, "title" | "body" | "sender">): string | null {
  const text = `${msg.title}\n${msg.body}`;
  if (isServiceNumberWithOptOut(msg.sender, text)) {
    return "规则判定：运营服务号含退订字样";
  }
  for (const k of JUNK_KEYWORDS) {
    if (text.includes(k)) return `规则判定：命中垃圾关键词「${k}」`;
  }
  return null;
}
