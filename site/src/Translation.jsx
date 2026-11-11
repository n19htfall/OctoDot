import { useEffect, useRef, useState } from "react";

const EXAMPLES = [
  { label: "中 → 英", keys: "zaoshanghao", preedit: "zao shang hao", source: "早上好", target: "Good morning", greeting: "Hi Alex," },
  { label: "英 → 中", keys: "morning", preedit: "morning", source: "morning", target: "早晨", greeting: "喜欢这样的" },
];
const STEPS = [
  { title: "照常输入", text: "打出拼音或英文，让想表达的词出现在候选栏。" },
  { title: "按住", keyLabel: "Option", text: "候选原地变成译文。松开按键，就回到原文。" },
  { title: "选中，直接输入", text: "保持按住 Option，按数字键选词，译文直接落在当前输入框。" },
];

function framesFor(example) {
  return [
    { phase: "typing", text: "", duration: 600 },
    ...Array.from(example.keys, (_, i) => ({ phase: "typing", text: example.keys.slice(0, i + 1), duration: 95 })),
    { phase: "candidate", text: example.preedit, duration: 1500 },
    { phase: "translated", text: example.preedit, duration: 2400 },
    { phase: "selecting", text: example.preedit, duration: 450 },
    { phase: "committed", text: example.target, duration: 2400 },
  ];
}

export default function Translation({ reduced }) {
  const demoRef = useRef(null);
  const [visible, setVisible] = useState(false);
  const [pageVisible, setPageVisible] = useState(true);
  const [exampleIndex, setExampleIndex] = useState(0);
  const [frameIndex, setFrameIndex] = useState(0);
  const example = EXAMPLES[exampleIndex];
  const frames = framesFor(example);
  const frame = frames[Math.min(frameIndex, frames.length - 1)];
  const committed = frame.phase === "committed";
  const held = frame.phase === "translated" || frame.phase === "selecting";
  const step = committed || frame.phase === "selecting" ? 2 : held ? 1 : 0;
  const running = visible && pageVisible && !reduced;

  useEffect(() => {
    const observer = new IntersectionObserver(([entry]) => setVisible(entry.isIntersecting), { threshold: 0.25 });
    observer.observe(demoRef.current);
    const onVisibility = () => setPageVisible(!document.hidden);
    onVisibility();
    document.addEventListener("visibilitychange", onVisibility);
    return () => {
      observer.disconnect();
      document.removeEventListener("visibilitychange", onVisibility);
    };
  }, []);

  useEffect(() => {
    if (reduced) setFrameIndex(framesFor(EXAMPLES[exampleIndex]).length - 3);
  }, [reduced, exampleIndex]);

  useEffect(() => {
    if (!running) return undefined;
    const timer = window.setTimeout(() => setFrameIndex((index) => (index + 1) % frames.length), frame.duration);
    return () => window.clearTimeout(timer);
  }, [running, frameIndex, exampleIndex, frame.duration, frames.length]);

  return (
    <section className="section" id="translation" aria-labelledby="translation-title">
      <div className="section-head reveal">
        <p className="eyebrow"><span className="idx">04</span>一键翻译</p>
        <h2 id="translation-title">一键，换种语言<i className="dot" aria-hidden="true" /></h2>
      </div>

      <div className="translation-layout reveal" ref={demoRef}>
        <div className="translation-guide">
          <p className="translation-kicker">输入体验照旧。</p>
          <ol className="translation-steps" aria-label="翻译操作步骤">
            {STEPS.map((item, index) => (
              <li key={item.title} aria-current={step === index ? "step" : undefined}>
                <span className="translation-step-number" aria-hidden="true">0{index + 1}</span>
                <div>
                  <strong>
                    {item.title}
                    {item.keyLabel && (
                      <kbd className="translation-inline-key">
                        <span aria-hidden="true">⌥</span>{item.keyLabel}
                      </kbd>
                    )}
                  </strong>
                  <p className="translation-step-copy">{item.text}</p>
                </div>
              </li>
            ))}
          </ol>
          <p className="translation-local"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" aria-hidden="true"><rect x="5" y="10" width="14" height="11" rx="3" /><path d="M8 10V7a4 4 0 0 1 8 0v3m-4 4v3" /></svg>翻译在本机完成。</p>
        </div>

        <div className={`translation-demo ${running ? "is-running" : ""}`} data-phase={frame.phase}>
          <div className="translation-toolbar">
            <div className="translation-directions" role="group" aria-label="演示翻译方向">
              {EXAMPLES.map((item, index) => (
                <button type="button" key={item.label} aria-pressed={exampleIndex === index} onClick={() => {
                  setExampleIndex(index);
                  setFrameIndex(reduced ? framesFor(item).length - 3 : 0);
                }}>{item.label}</button>
              ))}
            </div>
            <span className="translation-demo-label">流程演示</span>
          </div>

          <div className="translation-window window" role="img" aria-label={`流程演示：输入 ${example.keys}，候选为「${example.source}」；按住 Option 显示「${example.target}」，保持按住并按 1 输入译文。`}>
            <div className="titlebar" aria-hidden="true">
              <span className="lights"><i /><i /><i /></span>
              <span className="window-title">随手写几句</span>
              <span className="translation-window-mark">八千点</span>
            </div>
            <div className="translation-document" aria-hidden="true">
              <p className="translation-greeting">{example.greeting}</p>
              <div className="translation-writing">
                <span className={`translation-result ${committed ? "shown" : ""}`}>{example.target}</span>
                <span className={`translation-input ${committed ? "hidden" : ""}`}><span className="preedit">{committed ? example.preedit : frame.text}</span></span>
                <span className="caret" />
              </div>
              <div className={`translation-candidates ${frame.phase !== "typing" && !committed ? "shown" : ""} ${held ? "is-translated" : ""}`}>
                <span className="translation-candidate-index">1</span>
                <span className="translation-candidate-word">
                  <span className="translation-original">{example.source}</span>
                  <span className="translation-target">{example.target}</span>
                </span>
                <span className="translation-language">{held ? (exampleIndex === 0 ? "EN" : "中") : (exampleIndex === 0 ? "中" : "EN")}</span>
              </div>
              <span className={`translation-done ${committed ? "shown" : ""}`}>✓ 译文已输入</span>
            </div>
          </div>

          <div className="translation-keyboard" aria-hidden="true">
            <div className="translation-key-hint"><span className="translation-status-dot" /><span>{committed ? "表达，顺手完成。" : held ? "按住，候选即译文。" : "像平时一样打字。"}</span></div>
            <div className="translation-keycaps">
              <kbd className={`translation-key option ${held ? "pressed" : ""}`}><span>⌥</span><small>option</small></kbd>
              <span className="translation-key-plus">+</span>
              <kbd className={`translation-key number ${frame.phase === "selecting" ? "pressed" : ""}`}>1</kbd>
            </div>
          </div>
        </div>
      </div>

    </section>
  );
}
