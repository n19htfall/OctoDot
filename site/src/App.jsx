import { useCallback, useEffect, useRef, useState } from "react";
import DotField from "./DotField.jsx";
import Translation from "./Translation.jsx";
import { candidatesFor, preeditOf, schemes } from "./lexicon.js";

const GITHUB = "https://github.com/n19htfall/OctoDot";
const RELEASES = `${GITHUB}/releases`;
/** The release the download buttons fetch, as its disk image straight from
 *  GitHub. Update both on each release: the image's name carries the version,
 *  and the size is the image's, as Finder shows it. */
const RELEASE = { version: "0.2.4", size: "419 MB" };
const DOWNLOAD = `${RELEASES}/download/v${RELEASE.version}/OctoDot-${RELEASE.version}.dmg`;
/** The same disk image on Quark's cloud drive, for those GitHub is slow for. */
const MIRROR = "https://pan.quark.cn/s/4917f5cbdafc";
const ICON = `${import.meta.env.BASE_URL}icon.png`;

/** The icon's gold dot, closing a headline the way 。 closes a sentence. */
function Dot() {
  return <i className="dot" aria-hidden="true" />;
}

const NAV = [
  { id: "privacy", label: "隐私" },
  { id: "isolation", label: "网络隔离" },
  { id: "accuracy", label: "准确率" },
  { id: "translation", label: "一键翻译" },
  { id: "features", label: "功能" },
];

/* Measured, never estimated: OctoDot by `make accuracy` (2026-11), Rime
   (librime with 万象's grammar model) from rime-schema-compare's report on
   the same sentences (docs/M2-grammar.md, docs/rerank-design.md). */
/** Sentences right as a whole, full pinyin (exact shares, rounded on display).
 *  macOS's built-in Pinyin was typed through only on zhihu120. */
const PEERS = { apple: "macOS 自带拼音", rime: "Rime + 万象语法模型" };
const ACCURACY = [
  {
    set: "知乎测试集",
    size: "120 句",
    ours: (91 / 120) * 100,
    peers: [
      { id: "apple", value: (80 / 120) * 100 },
      { id: "rime", value: (72 / 120) * 100 },
    ],
  },
  {
    set: "语料测试",
    size: "3,392 句真实网络文本",
    ours: (2442 / 3392) * 100,
    peers: [{ id: "rime", value: 63.85 }],
    note: "macOS 自带输入法没测因为懒 😋",
  },
];

/** The 120 sentences one dot each: how many each input method got right. */
const UNIT_TOTAL = 120;
const UNITS = [
  { id: "ours", name: "八千点", right: Math.round((ACCURACY[0].ours / 100) * UNIT_TOTAL) },
  ...ACCURACY[0].peers.map((peer) => ({
    id: peer.id,
    name: peer.id === "apple" ? "macOS 自带拼音" : "Rime",
    right: Math.round((peer.value / 100) * UNIT_TOTAL),
  })),
];

const PERMISSIONS = [
  { name: "网络", denied: true },
  { name: "辅助功能", denied: true },
  { name: "输入监控", denied: true },
  { name: "剪贴板", denied: true },
  { name: "完全磁盘访问", denied: true },
  { name: "输入法框架 InputMethodKit", denied: false },
];

const PRIVACY = [
  { icon: "box", title: "运行在系统沙盒里", text: "输入法进程由 macOS 的 App Sandbox 隔离，只能读写自己的容器。" },
  { icon: "lock", title: "学到的词，加密保存", text: "用户词库以 AES-GCM 加密，密钥放在钥匙串里，只有输入法自己读得到。" },
  { icon: "eye", title: "敏感场景不学习", text: "密码框、无痕模式和你指定的 App 里，打过的字不会被记住。" },
  { icon: "chip", title: "端侧 AI", text: "为整句排序的神经网络在本机运行。没有云端，没有上传。" },
];

const STEPS = [
  { n: "1", title: "只有 OctoDot.app 联网", text: "检查与下载更新的，是你拖进「应用程序」的那个 App。它看不到你的任何输入。" },
  { n: "2", title: "签名机制", text: "发布清单用 Ed25519 签名，下载文件再核对 SHA-256。" },
  { n: "3", title: "输入法零网络权限", text: "看得到按键的 OctoDotIME 没有网络权限。就算想连，macOS 沙盒也会拒绝。" },
  { n: "4", title: "更新不打断输入", text: "新内核在原进程里热加载，正在打字的 App 不需要重启，也不会断开。" },
];

const FEATURES = [
  { tag: "方案", title: "全拼与小鹤双拼", text: "同一套词库，随时切换。双拼时，输入区按音节显示你实际按下的键。", sample: "zhong guo · vs go" },
  { tag: "中英", title: "中英文混合输入", text: "打 woyonggithub，直接得到「我用GitHub」。常用英文单词也会出现在候选里。", sample: "我用GitHub" },
  { tag: "可选", title: "模糊音", text: "z = zh、n = l 等十组，按需单独开启，默认全部关闭。", sample: "zong → 中" },
  { tag: "形码", title: "形码辅助筛字", text: "万象、墨奇、自然码等九套形码。打音节后加反引号，用字形缩小范围。", sample: "shi`o → 是" },
  { tag: "学习", title: "记住你的选择", text: "选过的词会靠前。也能一键忘掉最近 15 分钟，或今天学到的全部。", sample: "越用越顺手" },
  { tag: "短语", title: "自定义短语", text: "在一个文本文件里写下你的常用语，保存后立刻生效。", sample: "yx → 我的邮箱" },
];

/* ---------- hooks ---------- */

function useReducedMotion() {
  const [reduced, setReduced] = useState(false);
  useEffect(() => {
    const query = window.matchMedia("(prefers-reduced-motion: reduce)");
    setReduced(query.matches);
    const onChange = () => setReduced(query.matches);
    query.addEventListener("change", onChange);
    return () => query.removeEventListener("change", onChange);
  }, []);
  return reduced;
}

/** Adds `in` to every `.reveal` once it scrolls into view. */
function useReveal() {
  useEffect(() => {
    const nodes = document.querySelectorAll(".reveal");
    const observer = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (entry.isIntersecting) {
            entry.target.classList.add("in");
            observer.unobserve(entry.target);
          }
        });
      },
      { rootMargin: "0px 0px -10% 0px", threshold: 0.15 },
    );
    nodes.forEach((node) => observer.observe(node));
    return () => observer.disconnect();
  }, []);
}

function useActiveSection() {
  const [active, setActive] = useState("");
  useEffect(() => {
    const nodes = NAV.map((item) => document.getElementById(item.id)).filter(Boolean);
    const observer = new IntersectionObserver(
      (entries) => {
        const visible = entries.filter((entry) => entry.isIntersecting)[0];
        if (visible) setActive(visible.target.id);
      },
      { rootMargin: "-45% 0px -50% 0px" },
    );
    nodes.forEach((node) => observer.observe(node));
    return () => observer.disconnect();
  }, []);
  return active;
}

/** Counts up to `to` (one decimal) when `ref` scrolls into view. It shows
 *  `to` until then, so the number is right wherever motion or the observer
 *  never happens (the card is still fading in when the count restarts). */
function useCountUp(to, ref) {
  const [value, setValue] = useState(to);
  useEffect(() => {
    const node = ref.current;
    if (!node) return undefined;
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
      setValue(to);
      return undefined;
    }
    let frame = 0;
    const observer = new IntersectionObserver(([entry]) => {
      if (!entry.isIntersecting) return;
      observer.disconnect();
      const start = performance.now();
      const tick = (now) => {
        const t = Math.min(1, (now - start) / 1400);
        setValue(to * (1 - Math.pow(1 - t, 3)));
        if (t < 1) frame = requestAnimationFrame(tick);
      };
      frame = requestAnimationFrame(tick);
    });
    observer.observe(node);
    return () => {
      observer.disconnect();
      cancelAnimationFrame(frame);
    };
  }, [to, ref]);
  return value;
}

/* ---------- icons ---------- */

function Icon({ name }) {
  const paths = {
    box: <path d="M12 2 3 6.5v11L12 22l9-4.5v-11L12 2Zm0 2.2 6.6 3.3L12 10.8 5.4 7.5 12 4.2ZM5 9.1l6 3v7.7l-6-3V9.1Zm8 10.7v-7.7l6-3v7.7l-6 3Z" />,
    lock: <path d="M12 2a5 5 0 0 0-5 5v3H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-8a2 2 0 0 0-2-2h-1V7a5 5 0 0 0-5-5Zm-3 5a3 3 0 0 1 6 0v3H9V7Zm3 7a2 2 0 0 1 1 3.7V19h-2v-1.3A2 2 0 0 1 12 14Z" />,
    eye: <path d="M2.3 4.7 3.7 3.3l17 17-1.4 1.4-3.3-3.3A10.6 10.6 0 0 1 12 19c-5 0-8.7-3.4-10-7a11.6 11.6 0 0 1 3.9-5.1L2.3 4.7Zm5 5A4 4 0 0 0 14.3 16l-1.6-1.6A2 2 0 0 1 9.6 11.3L7.3 9.7ZM12 5c5 0 8.7 3.4 10 7a11.4 11.4 0 0 1-2.6 3.9l-1.4-1.4A9.4 9.4 0 0 0 19.9 12C18.7 9.2 15.6 7 12 7c-.9 0-1.7.1-2.5.4L7.9 5.8A10.5 10.5 0 0 1 12 5Z" />,
    chip: <path d="M9 2h2v2h2V2h2v2h2a2 2 0 0 1 2 2v2h2v2h-2v2h2v2h-2v2a2 2 0 0 1-2 2h-2v2h-2v-2h-2v2H9v-2H7a2 2 0 0 1-2-2v-2H3v-2h2v-2H3V8h2V6a2 2 0 0 1 2-2h2V2Zm-2 4v12h10V6H7Zm2 2h6v8H9V8Z" />,
    cloud: <path d="M7 19a5 5 0 0 1-.6-10A6 6 0 0 1 18 8.6 4.7 4.7 0 0 1 17.5 19H7Z" />,
    app: <path d="M6 3h12a3 3 0 0 1 3 3v12a3 3 0 0 1-3 3H6a3 3 0 0 1-3-3V6a3 3 0 0 1 3-3Zm0 2a1 1 0 0 0-1 1v12a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1V6a1 1 0 0 0-1-1H6Zm6 3 4 4-4 4-1.4-1.4 1.6-1.6H8v-2h4.2l-1.6-1.6L12 8Z" />,
    keyboard: <path d="M3 6h18a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2Zm0 2v8h18V8H3Zm2 1h2v2H5V9Zm3 0h2v2H8V9Zm3 0h2v2h-2V9Zm3 0h2v2h-2V9Zm3 0h2v2h-2V9ZM6 13h12v2H6v-2Z" />,
    check: <path d="m9.5 16.2-4.2-4.2-1.4 1.4 5.6 5.6L21 7.5l-1.4-1.4L9.5 16.2Z" />,
    cross: <path d="M18.3 5.7 12 12l6.3 6.3-1.4 1.4L10.6 13.4 4.3 19.7l-1.4-1.4L9.2 12 2.9 5.7l1.4-1.4 6.3 6.3 6.3-6.3 1.4 1.4Z" />,
    download: <path d="M11 3h2v9.2l3.3-3.3 1.4 1.4L12 16l-5.7-5.7 1.4-1.4 3.3 3.3V3ZM4 15h2v4h12v-4h2v4a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2v-4Z" />,
    /* GitHub's mark, where the download comes from. */
    github: <path d="M12 .297c-6.63 0-12 5.373-12 12 0 5.303 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 0-.285-.01-1.04-.015-2.04-3.338.724-4.042-1.61-4.042-1.61C4.422 18.07 3.633 17.7 3.633 17.7c-1.087-.744.084-.729.084-.729 1.205.084 1.838 1.236 1.838 1.236 1.07 1.835 2.809 1.305 3.495.998.108-.776.417-1.305.76-1.605-2.665-.3-5.466-1.332-5.466-5.93 0-1.31.465-2.38 1.235-3.22-.135-.303-.54-1.523.105-3.176 0 0 1.005-.322 3.3 1.23.96-.267 1.98-.399 3-.405 1.02.006 2.04.138 3 .405 2.28-1.552 3.285-1.23 3.285-1.23.645 1.653.24 2.873.12 3.176.765.84 1.23 1.91 1.23 3.22 0 4.61-2.805 5.625-5.475 5.92.42.36.81 1.096.81 2.22 0 1.606-.015 2.896-.015 3.286 0 .315.21.69.825.57C20.565 22.092 24 17.592 24 12.297c0-6.627-5.373-12-12-12" />,
  };
  return (
    <svg className="icon" viewBox="0 0 24 24" aria-hidden="true" focusable="false">
      {paths[name]}
    </svg>
  );
}

/** Drawn in strokes, lighter than the filled set above: for a text link. */
function DownloadOutlineIcon() {
  return (
    <svg className="icon outline" viewBox="0 0 24 24" aria-hidden="true" focusable="false">
      <path d="M12 4v11m-4.5-4.5L12 15l4.5-4.5M5 15v3a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-3" />
    </svg>
  );
}

function DownloadButton({ small = false, icon = "download" }) {
  return (
    <a className={small ? "btn small" : "btn download"} href={DOWNLOAD}>
      <Icon name={icon} />
      下载
    </a>
  );
}

/* ---------- hero demo: a Mac window with OctoDot's candidate bar ---------- */

/** The samples it types, in order: full pinyin's, then 小鹤双拼's. */
const SCRIPT = [
  ...schemes.quanpin.samples.map((sample) => ({ scheme: "quanpin", ...sample })),
  ...schemes.flypy.samples.map((sample) => ({ scheme: "flypy", ...sample })),
];

/** A Mac window typing by itself with OctoDot's candidate bar: to look at,
 *  not to use. Each sample is typed key by key, its first candidate goes up,
 *  and the next one follows. */
function Demo({ onLead, onCommit }) {
  const [schemeId, setSchemeId] = useState("quanpin");
  const [raw, setRaw] = useState("");
  const [committed, setCommitted] = useState("");
  const scheme = schemes[schemeId];
  const preedit = preeditOf(raw, scheme);
  const candidates = candidatesFor(raw, scheme);
  /* What the dot field spells: the first character of what is about to go
     up, or of what just did. */
  const lead = Array.from(committed || candidates[0] || "")[0];

  useEffect(() => {
    if (lead) onLead(lead);
  }, [lead, onLead]);

  useEffect(() => {
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
      setRaw("woyonggithub");
      return undefined;
    }
    let item = 0;
    let count = 0;
    let timer = 0;
    const step = () => {
      const { scheme: id, keys, text } = SCRIPT[item];
      setSchemeId(id);
      if (count < keys.length) {
        count += 1;
        setRaw(keys.slice(0, count));
        timer = window.setTimeout(step, 110);
        return;
      }
      timer = window.setTimeout(() => {
        setCommitted(text);
        setRaw("");
        onCommit();
        timer = window.setTimeout(() => {
          setCommitted("");
          item = (item + 1) % SCRIPT.length;
          count = 0;
          step();
        }, 1300);
      }, 1200);
    };
    timer = window.setTimeout(step, 900);
    return () => window.clearTimeout(timer);
  }, [onCommit]);

  return (
    <div className="demo" role="img" aria-label="演示：在备忘录里用八千点打字，全拼与小鹤双拼，候选栏给出词语">
      <div className="window" aria-hidden="true">
        <div className="titlebar">
          <span className="lights">
            <i />
            <i />
            <i />
          </span>
          <span className="window-title">备忘录</span>
        </div>
        <div className="doc">
          <p className="line">
            <span className="typed">{committed}</span>
            {preedit ? <span className="preedit">{preedit}</span> : null}
            <span className="caret" />
          </p>
          <div className={`candbar ${candidates.length ? "shown" : ""}`}>
            {candidates.map((word, index) => (
              <span key={word} className={index === 0 ? "picked" : ""}>
                <span className="idx">{index + 1}</span>
                {word}
              </span>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}

/* ---------- sections ---------- */

function Privacy() {
  return (
    <section className="section" id="privacy" aria-labelledby="privacy-title">
      <div className="section-head reveal">
        <p className="eyebrow">
          <span className="idx">01</span>
          原则
        </p>
        <h2 id="privacy-title">
          隐私优先
          <Dot />
        </h2>
        <p className="section-lede">
          八千点从架构上靠系统的隔离机制不给这些输入离开的机会。
        </p>
      </div>
      <div className="privacy-grid">
        <div className="perm-card reveal">
          <p className="perm-title">八千点输入法请求的权限</p>
          <ul className="perms">
            {PERMISSIONS.map((item) => (
              <li key={item.name} className={item.denied ? "denied" : "granted"}>
                <span className="perm-mark">
                  <Icon name={item.denied ? "cross" : "check"} />
                </span>
                <span>{item.name}</span>
                <span className="perm-state">{item.denied ? "不请求" : "仅此一项"}</span>
              </li>
            ))}
          </ul>
        </div>
        <div className="cards">
          {PRIVACY.map((item, index) => (
            <article className="card reveal" key={item.title} style={{ "--delay": `${index * 70}ms` }}>
              <span className="card-icon">
                <Icon name={item.icon} />
              </span>
              <h3>{item.title}</h3>
              <p>{item.text}</p>
            </article>
          ))}
        </div>
      </div>
    </section>
  );
}

function Isolation() {
  return (
    <section className="section dark" id="isolation" aria-labelledby="isolation-title">
      <div className="dark-inner">
        <div className="section-head reveal">
          <p className="eyebrow">
          <span className="idx">02</span>
          隔离
        </p>
          <h2 id="isolation-title">
          断网沙盒
          <Dot />
        </h2>
          <p className="section-lede">
            八千点输入法拆成两个程序。负责更新的 OctoDot.app 可以联网，却看不到按键；实际输入的 OctoDotIME 被关在断网沙盒里，无法向外传输数据。
          </p>
        </div>

        <figure className="iso reveal" aria-labelledby="iso-caption">
          <div className="iso-node net">
            <Icon name="cloud" />
            <strong>互联网</strong>
            <span>GitHub Releases</span>
          </div>

          <div className="iso-link ok" aria-hidden="true">
            <span className="iso-label">签名更新</span>
            <span className="track">
              <i className="pkt" />
              <i className="pkt late" />
            </span>
          </div>

          <div className="iso-node app">
            <Icon name="app" />
            <strong>OctoDot.app</strong>
            <span>检查更新 · 安装 · 卸载</span>
            <em className="seal">
              <Icon name="check" /> Ed25519 验签
            </em>
          </div>

          <div className="iso-link ok" aria-hidden="true">
            <span className="iso-label">安装 · 热加载</span>
            <span className="track">
              <i className="pkt slow" />
            </span>
          </div>

          <div className="sandbox">
            <p className="sandbox-tag">
              <Icon name="lock" /> macOS 沙盒
            </p>
            <div className="sb-row">
              <div className="keyflow" aria-hidden="true">
                <span className="keys">
                  {"nihao".split("").map((key, index) => (
                    <kbd key={index} style={{ "--i": index }}>
                      {key}
                    </kbd>
                  ))}
                </span>
                <span className="arrow">→</span>
                <span className="out">你好</span>
              </div>
              <p className="keyflow-label">按键进来，文字只回到你正在用的 App</p>
            </div>
            <div className="iso-node ime">
              <Icon name="keyboard" />
              <strong>OctoDotIME</strong>
              <span>看得到按键，碰不到网络</span>
            </div>
            <div className="sb-row">
              <div className="blocked" aria-hidden="true">
                <span className="wall" />
                <span className="lane">
                  <i className="pkt bad" />
                </span>
                <span className="bang">
                  <Icon name="cross" />
                </span>
              </div>
              <p className="blocked-label">试图联网 → 被系统拒绝</p>
            </div>
          </div>
          <figcaption id="iso-caption" className="visually-hidden">
            更新从互联网经过签名校验进入 OctoDot.app，再安装到输入法；输入法本身在沙盒中，试图联网会被拒绝，按键只在本机变成文字。
          </figcaption>
        </figure>

        <ol className="steps">
          {STEPS.map((step, index) => (
            <li className="step reveal" key={step.n} style={{ "--delay": `${index * 80}ms` }}>
              <span className="step-n">{step.n}</span>
              <h3>{step.title}</h3>
              <p>{step.text}</p>
            </li>
          ))}
        </ol>
      </div>
    </section>
  );
}

function Accuracy() {
  const bigRef = useRef(null);
  const big = useCountUp(75.8, bigRef);
  const [whole, tenth] = big.toFixed(1).split(".");
  return (
    <section className="section" id="accuracy" aria-labelledby="accuracy-title">
      <div className="section-head reveal">
        <p className="eyebrow">
          <span className="idx">03</span>
          准确率
        </p>
        <h2 id="accuracy-title">
          对吗？对的
          <Dot />
        </h2>
        <p className="section-lede">
          训练了一个小神经网络用来重排序, and it just works.
        </p>
      </div>

      <div className="acc-grid">
        <div className="acc-hero reveal" ref={bigRef}>
          <p className="acc-number">
            {whole}
            <i className="point">.</i>
            {tenth}
            <span>%</span>
          </p>
          <p className="acc-caption">整句一次打对</p>
          <p className="acc-sub">测试集结果</p>
          <div className="acc-chip">
            <strong>错句比 macOS 自带拼音少 27.5%</strong>
            {/* <span>同一组 {UNIT_TOTAL} 句，一个点是一句</span> */}
            <div
              className="units"
              role="img"
              aria-label={`同一组 ${UNIT_TOTAL} 句：${UNITS.map((unit) => `${unit.name}错 ${UNIT_TOTAL - unit.right} 句`).join("，")}`}
            >
              {UNITS.map((unit) => (
                <div className={`unit ${unit.id}`} key={unit.id} aria-hidden="true">
                  <div className="unit-dots">
                    {Array.from({ length: UNIT_TOTAL }, (_, index) => (
                      <i key={index} className={index < unit.right ? "hit" : ""} style={{ "--i": index }} />
                    ))}
                  </div>
                  <p className="unit-name">{unit.name}</p>
                  <p className="unit-count">
                    错 <strong>{UNIT_TOTAL - unit.right}</strong> 句
                  </p>
                </div>
              ))}
            </div>
          </div>
        </div>

        <div className="acc-chart reveal">
          <div className="legend" aria-hidden="true">
            <span className="key ours">八千点</span>
            {Object.entries(PEERS).map(([id, name]) => (
              <span className={`key ${id}`} key={id}>
                {name}
              </span>
            ))}
          </div>
          {ACCURACY.map((row) => (
            <div className="bar-group" key={row.set}>
              <div className="bar-head">
                <h3>{row.set}</h3>
                <span>{row.size}</span>
              </div>
              <div className="bar ours" style={{ "--v": row.ours }} aria-label={`八千点 ${row.ours.toFixed(1)}%`}>
                <span className="fill" />
                <span className="value">{row.ours.toFixed(1)}%</span>
              </div>
              {row.peers.map((peer) => (
                <div
                  className={`bar ${peer.id}`}
                  style={{ "--v": peer.value }}
                  key={peer.id}
                  aria-label={`${PEERS[peer.id]} ${peer.value.toFixed(1)}%`}
                >
                  <span className="fill" />
                  <span className="value">{peer.value.toFixed(1)}%</span>
                </div>
              ))}
              <p className="delta">
                {row.peers.map((peer, index) => (
                  <span key={peer.id}>
                    {index > 0 ? "，" : ""}
                    <span className="nowrap">
                      比 {PEERS[peer.id]}高 <strong>{(row.ours - peer.value).toFixed(1)}</strong>
                    </span>
                  </span>
                ))}{" "}
                个百分点
              </p>
              {row.note ? <p className="delta-note">{row.note}</p> : null}
            </div>
          ))}
          <p className="source">
            全拼，整句完全正确的比例。
          </p>
        </div>
      </div>
    </section>
  );
}

function Features() {
  return (
    <section className="section" id="features" aria-labelledby="features-title">
      <div className="section-head reveal">
        <p className="eyebrow">
          <span className="idx">05</span>
          其他功能
        </p>
        <h2 id="features-title">
          早晚用得上
          <Dot />
        </h2>
      </div>
      <div className="feature-grid">
        {FEATURES.map((item, index) => (
          <article className="feature reveal" key={item.title} style={{ "--delay": `${(index % 3) * 70}ms` }}>
            <span className="feature-tag">{item.tag}</span>
            <h3>{item.title}</h3>
            <p>{item.text}</p>
            <p className="feature-sample">{item.sample}</p>
          </article>
        ))}
      </div>
    </section>
  );
}

/** The hero and the figures under it, over the dot field. The field spells
 *  the character the demo is typing, so the two share this state. */
function Top() {
  const hostRef = useRef(null);
  const slotRef = useRef(null);
  const [lead, setLead] = useState("千");
  const [pulse, setPulse] = useState(0);
  const commit = useCallback(() => setPulse((count) => count + 1), []);

  return (
    <>
      <div className="hero-wrap" ref={hostRef}>
        <DotField char={lead} pulse={pulse} hostRef={hostRef} slotRef={slotRef} />
        <section className="hero" id="top" aria-labelledby="hero-title">
          <div className="hero-copy">
            <p className="hero-eyebrow">
              八千点 · 中文输入法
              <span className="ver">v{RELEASE.version}</span>
            </p>
            <h1 id="hero-title">
              隐私、效率，
              <br />
              现已支持
              <span className="nowrap">
                {" "}
                macOS
                <Dot />
              </span>
            </h1>
            <p className="hero-lede">
              <span className="nowrap">八千点是隐私优先的中文输入法，</span>
              <span className="nowrap">目前支持全拼与小鹤双拼。</span>
            </p>
            <div className="hero-actions">
              <DownloadButton icon="github" />
              <a className="link" href="#isolation">
                输入法架构 <span aria-hidden="true">→</span>
              </a>
            </div>
            <p className="hero-meta">
              macOS 14 及以上 · Apple 芯片
              <a className="mirror" href={MIRROR}>
                <DownloadOutlineIcon />
                备用下载链接
              </a>
            </p>
          </div>
          <div className="stage">
            <div className="glyph-slot" ref={slotRef} aria-hidden="true" />
            <Demo onLead={setLead} onCommit={commit} />
          </div>
        </section>
      </div>

      <section className="stats" aria-label="要点">
        <div className="stat reveal">
          <strong>75.8%</strong>
          <span>
            长句准确率<span className="nowrap"></span>
          </span>
        </div>
        <div className="stat reveal" style={{ "--delay": "70ms" }}>
          <strong>+9.2%</strong>
          <span>
            对比macOS自带输入法<span className="nowrap"></span>
          </span>
        </div>
        <div className="stat reveal" style={{ "--delay": "140ms" }}>
          <strong>0</strong>
          <span>输入法的网络权限</span>
        </div>
        <div className="stat reveal" style={{ "--delay": "210ms" }}>
          <strong>本地</strong>
          <span>词库、记忆与 AI 只留在本机</span>
        </div>
      </section>
    </>
  );
}

export default function App() {
  useReveal();
  const active = useActiveSection();
  const reduced = useReducedMotion();

  return (
    <div className={reduced ? "reduced" : ""}>
      <a className="skip" href="#main">
        跳到正文
      </a>
      <header className="nav">
        <div className="nav-inner">
          <a className="brand" href="#top" aria-label="八千点 OctoDot，回到页首">
            <img src={ICON} alt="" width="30" height="30" />
            <span>
              八千点 <em>OctoDot</em>
            </span>
          </a>
          <nav aria-label="本页">
            {NAV.map((item) => (
              <a key={item.id} href={`#${item.id}`} className={active === item.id ? "on" : ""}>
                {item.label}
              </a>
            ))}
          </nav>
          <DownloadButton small />
        </div>
      </header>

      <main id="main">
        <Top />

        <Privacy />
        <Isolation />
        <Accuracy />
        <Translation reduced={reduced} />
        <Features />

        <section className="cta reveal" aria-labelledby="cta-title">
          <img src={ICON} alt="" width="72" height="72" />
          <h2 id="cta-title">八千点 OctoDot</h2>
          <p>即刻下载体验。</p>
          <div className="hero-actions center">
            <DownloadButton icon="github" />
            <a className="btn ghost" href={GITHUB}>
              在 GitHub 上查看
            </a>
          </div>
        </section>
      </main>

      <footer className="footer">
        <div className="footer-inner">
          <span>八千点 OctoDot</span>
          <span>
            内置词库来自万象（CC BY 4.0）· <a href={GITHUB}>github.com/n19htfall/OctoDot</a>
          </span>
        </div>
      </footer>
    </div>
  );
}
