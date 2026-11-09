/** A handful of real OctoDot spellings, enough to feel the candidate bar.
 *  The page says so. The input method itself uses the 万象 lexicon. */

const quanpin = {
  id: "quanpin",
  label: "全拼",
  syllables: ["zhong", "guo", "ni", "hao", "ba", "qian", "dian", "shu", "ru", "fa", "shi", "yin", "si", "zi", "wo", "yong", "github"],
  entries: [
    { k: "zhong", w: ["中", "重", "种"] },
    { k: "zhongguo", w: ["中国"] },
    { k: "ni", w: ["你", "泥", "尼"] },
    { k: "nihao", w: ["你好"] },
    { k: "ba", w: ["八", "吧", "把"] },
    { k: "baqiandian", w: ["八千点"] },
    { k: "baqiandianshurufa", w: ["八千点输入法"] },
    { k: "shi", w: ["是", "时", "十"] },
    { k: "shishi", w: ["实时", "事实"] },
    { k: "yin", w: ["音", "因", "隐"] },
    { k: "yinsi", w: ["隐私"] },
    { k: "zi", w: ["字", "自", "子"] },
    { k: "wo", w: ["我", "握", "窝"] },
    { k: "woyong", w: ["我用"] },
    { k: "woyonggithub", w: ["我用GitHub"] },
  ],
  samples: [
    { keys: "nihao", text: "你好" },
    { keys: "yinsi", text: "隐私" },
    { keys: "woyonggithub", text: "我用GitHub" },
    { keys: "baqiandianshurufa", text: "八千点输入法" },
  ],
};

const flypy = {
  id: "flypy",
  label: "小鹤双拼",
  syllables: ["vs", "go", "ba", "qm", "dm", "uu", "ru", "fa", "ui"],
  entries: [
    { k: "vs", w: ["中", "重", "种"] },
    { k: "vsgo", w: ["中国"] },
    { k: "ba", w: ["八", "吧", "把"] },
    { k: "baqmdm", w: ["八千点"] },
    { k: "baqmdmuurufa", w: ["八千点输入法"] },
    { k: "ui", w: ["时", "是", "十"] },
    { k: "uiui", w: ["实时"] },
  ],
  samples: [
    { keys: "vsgo", text: "中国" },
    { keys: "uiui", text: "实时" },
    { keys: "baqmdmuurufa", text: "八千点输入法" },
  ],
};

export const schemes = { quanpin, flypy };

export function segment(raw, syllables) {
  const sorted = [...syllables].sort((a, b) => b.length - a.length);
  const parts = [];
  let i = 0;
  const s = raw.toLowerCase();
  while (i < s.length) {
    const hit = sorted.find((syl) => s.startsWith(syl, i));
    if (hit) {
      parts.push(hit);
      i += hit.length;
    } else {
      parts.push(s.slice(i));
      break;
    }
  }
  return parts;
}

export function preeditOf(raw, scheme) {
  if (!raw) return "";
  return segment(raw, scheme.syllables).join(" ");
}

export function candidatesFor(raw, scheme) {
  if (!raw) return [];
  const exact = scheme.entries.find((e) => e.k === raw);
  const longer = scheme.entries.filter((e) => e.k.startsWith(raw) && e.k !== raw);
  const words = [];
  const push = (w) => {
    if (!words.includes(w)) words.push(w);
  };
  exact?.w.forEach(push);
  longer.forEach((e) => e.w.forEach(push));
  // As the input method does: then the first syllable's own characters.
  const first = segment(raw, scheme.syllables)[0];
  if (first && first !== raw) scheme.entries.find((e) => e.k === first)?.w.forEach(push);
  return words.slice(0, 5);
}
