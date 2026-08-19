(function () {
  "use strict";

  const root = document.documentElement;
  const languageButton = document.querySelector(".language-toggle");
  let english = false;
  let layoutHexDetails = function () {};
  let syncTextCarouselsLanguage = function () {};

  // The landing page is deliberately a four-chapter desktop story. Keep the
  // workflow cards with the technical chapter instead of leaving a fifth,
  // disconnected scroll section below the 3D studio.
  const flowSection = document.querySelector(".flow-section");
  const featuresSection = document.querySelector(".features-section");
  const workflowLoop = document.querySelector(".workflow-loop");
  const selfHostSection = document.querySelector(".self-host");
  const desktopChapterLayout = window.matchMedia("(min-width: 961px)");
  const workflowOriginalParent = workflowLoop?.parentElement || null;
  document.querySelector(".hero")?.classList.add("chapter", "chapter-hero");
  flowSection?.classList.add("chapter", "chapter-studio");
  featuresSection?.classList.add("chapter", "chapter-code");
  selfHostSection?.classList.add("chapter", "chapter-open");
  function placeWorkflowLoop() {
    if (!workflowLoop || !featuresSection || !workflowOriginalParent) return;
    workflowLoop.classList.remove("reveal");
    if (desktopChapterLayout.matches) {
      featuresSection.insertBefore(workflowLoop, featuresSection.firstElementChild);
    } else if (workflowLoop.parentElement !== workflowOriginalParent) {
      workflowOriginalParent.appendChild(workflowLoop);
    }
  }
  placeWorkflowLoop();
  window.requestAnimationFrame(placeWorkflowLoop);
  window.addEventListener("resize", placeWorkflowLoop, { passive: true });
  desktopChapterLayout.addEventListener("change", placeWorkflowLoop);
  document.querySelectorAll(
    ".features-section > .section-intro, .features-section > .harmony-native, .features-section > .engineering-ledger",
  ).forEach(function (item) {
    item.classList.remove("reveal");
    item.classList.add("visible");
  });
  document.body.classList.add("four-chapter-site");

  function updateLanguage() {
    root.lang = english ? "en" : "zh-CN";
    document.querySelectorAll("[data-zh][data-en]").forEach(function (node) {
      node.innerHTML = english ? node.dataset.en : node.dataset.zh;
    });
    layoutHexDetails();
    syncFeatureLabLanguage();
    syncTextCarouselsLanguage();
    if (window.gsap) setupCurtainReveals(true);
    if (languageButton) {
      languageButton.textContent = english ? "中文" : "EN";
      languageButton.setAttribute(
        "aria-label",
        english ? "Switch to Chinese" : "切换至英文",
      );
    }
  }

  if (languageButton) {
    languageButton.addEventListener("click", function () {
      english = !english;
      updateLanguage();
      if (orbitTimeline) setToggleState(orbitTimeline.paused());
    });
  }

  function setupTextCarousels() {
    const elements = Array.from(document.querySelectorAll("[data-carousel-zh][data-carousel-en]"));
    if (!elements.length) return;

    const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
    const segmenter = typeof Intl !== "undefined" && "Segmenter" in Intl
      ? new Intl.Segmenter("zh-CN", { granularity: "grapheme" })
      : null;
    const states = elements.map(function (element) {
      return {
        element,
        badge: element.querySelector(".text-carousel-badge"),
        content: element.querySelector(".text-carousel-content"),
        index: 0,
        animating: false,
        firstRender: true,
      };
    }).filter(function (state) {
      return state.badge && state.content;
    });

    function getTexts(state) {
      const source = english ? state.element.dataset.carouselEn : state.element.dataset.carouselZh;
      return String(source || "").split("|").filter(Boolean);
    }

    function splitCharacters(text) {
      if (segmenter) {
        return Array.from(segmenter.segment(text), function (part) {
          return part.segment;
        });
      }
      return Array.from(text);
    }

    function renderState(state, animateIn) {
      const texts = getTexts(state);
      if (!texts.length) return;
      state.index %= texts.length;
      const text = texts[state.index];
      const fragment = document.createDocumentFragment();

      splitCharacters(text).forEach(function (character) {
        const span = document.createElement("span");
        span.className = "text-carousel-char";
        span.textContent = character === " " ? "\u00a0" : character;
        fragment.appendChild(span);
      });

      state.content.replaceChildren(fragment);
      state.content.setAttribute("aria-hidden", "true");
      state.element.setAttribute("aria-label", text);
      const computed = window.getComputedStyle(state.badge);
      const horizontalPadding = parseFloat(computed.paddingLeft) + parseFloat(computed.paddingRight);
      const nextWidth = Math.ceil(state.content.scrollWidth + horizontalPadding);
      const characters = state.content.querySelectorAll(".text-carousel-char");

      if (!window.gsap || reducedMotion.matches) {
        state.badge.style.width = `${nextWidth}px`;
        state.animating = false;
        state.firstRender = false;
        return;
      }

      gsap.killTweensOf(state.badge);
      gsap.killTweensOf(characters);
      if (state.firstRender || !animateIn) {
        gsap.set(state.badge, { width: nextWidth });
        gsap.set(characters, { yPercent: 0, autoAlpha: 1 });
        state.animating = false;
        state.firstRender = false;
        return;
      }

      gsap.to(state.badge, {
        width: nextWidth,
        duration: 0.46,
        ease: "power3.out",
        overwrite: "auto",
      });
      gsap.fromTo(
        characters,
        { yPercent: 112, autoAlpha: 0 },
        {
          yPercent: 0,
          autoAlpha: 1,
          duration: 0.42,
          stagger: { each: 0.026, from: "start" },
          ease: "power3.out",
          onComplete: function () {
            state.animating = false;
          },
        },
      );
    }

    function rotateState(state) {
      if (state.animating || reducedMotion.matches) return;
      const texts = getTexts(state);
      if (texts.length < 2) return;
      const characters = state.content.querySelectorAll(".text-carousel-char");
      state.animating = true;

      if (!window.gsap || !characters.length) {
        state.index = (state.index + 1) % texts.length;
        renderState(state, false);
        return;
      }

      gsap.killTweensOf(characters);
      gsap.to(characters, {
        yPercent: -118,
        autoAlpha: 0,
        duration: 0.34,
        stagger: { each: 0.022, from: "start" },
        ease: "power2.in",
        onComplete: function () {
          state.index = (state.index + 1) % texts.length;
          renderState(state, true);
        },
      });
    }

    states.forEach(function (state, index) {
      renderState(state, false);
      if (reducedMotion.matches) return;
      window.setTimeout(function () {
        rotateState(state);
        window.setInterval(function () {
          rotateState(state);
        }, 2800);
      }, 2400 + index * 420);
    });

    syncTextCarouselsLanguage = function () {
      states.forEach(function (state) {
        if (window.gsap) {
          gsap.killTweensOf(state.badge);
          gsap.killTweensOf(state.content.querySelectorAll(".text-carousel-char"));
        }
        state.index = 0;
        state.animating = false;
        renderState(state, false);
      });
    };
  }

  setupTextCarousels();

  function setupSupporterWall() {
    const wall = document.querySelector("[data-supporter-wall]");
    if (!wall) return;
    const tracks = Array.from(wall.querySelectorAll("[data-supporter-track]"));
    if (!tracks.length) return;

    const technologies = [
      { mark: "A", icon: "harmonyos", name: "ArkTS", zh: "鸿蒙原生客户端", en: "HarmonyOS native client" },
      { mark: "Go", icon: "go", name: "Go", zh: "后端与远程桥接", en: "Backend and remote bridge" },
      { mark: "Py", icon: "python", name: "Python", zh: "审批 Hook 与本地 Agent", en: "Approval hooks and local agent" },
      { mark: "JS", icon: "javascript", name: "JavaScript", zh: "网站与交互逻辑", en: "Website and interaction logic" },
      { mark: "TS", icon: "typescript", name: "TypeScript", zh: "类型化工具代码", en: "Typed tooling" },
      { mark: "C++", icon: "cplusplus", name: "C / C++", zh: "Windows 原生远控", en: "Native Windows remote control" },
      { mark: "N", icon: "nodedotjs", name: "Node.js", zh: "PTY 与 Relay 编排", en: "PTY and relay orchestration" },
      { mark: "PS", iconUrl: "https://cdn.jsdelivr.net/gh/devicons/devicon@latest/icons/powershell/powershell-original.svg", name: "PowerShell", zh: "构建与运维脚本", en: "Build and operations scripts" },
      { mark: "<>", icon: "html5", name: "HTML", zh: "官网语义结构", en: "Website semantics" },
      { mark: "#", icon: "css", name: "CSS", zh: "视觉与页面动效", en: "Visuals and page motion" },
      { mark: "DB", icon: "sqlite", name: "SQLite", zh: "本地状态与审计", en: "Local state and audit data" },
      { mark: "RTC", icon: "webrtc", name: "WebRTC", zh: "远程桌面媒体链路", en: "Remote desktop media path" },
    ];

    function createTechnologyChip(item) {
      const chip = document.createElement("span");
      chip.className = "stack-chip stack-chip-tech";
      const icon = document.createElement("span");
      icon.className = "stack-chip-icon stack-chip-tech-icon";
      const iconUrl = item.iconUrl || `https://cdn.simpleicons.org/${item.icon}/8F6254`;
      icon.style.setProperty("--stack-icon", `url("${iconUrl}")`);
      const copy = document.createElement("span");
      copy.className = "stack-chip-copy";
      const name = document.createElement("strong");
      name.textContent = item.name;
      const role = document.createElement("small");
      role.dataset.zh = item.zh;
      role.dataset.en = item.en;
      role.textContent = english ? item.en : item.zh;
      copy.append(name, role);
      chip.append(icon, copy);
      return chip;
    }

    function createSupporterChip(user) {
      const chip = document.createElement("a");
      chip.className = "stack-chip stack-chip-person";
      chip.href = user.html_url;
      chip.target = "_blank";
      chip.rel = "noreferrer";
      const icon = document.createElement("span");
      icon.className = "stack-chip-icon";
      const avatar = document.createElement("img");
      avatar.src = user.avatar_url;
      avatar.alt = "";
      avatar.loading = "lazy";
      icon.append(avatar);
      const copy = document.createElement("span");
      copy.className = "stack-chip-copy";
      const name = document.createElement("strong");
      name.textContent = `@${user.login}`;
      const role = document.createElement("small");
      role.textContent = "STARRED SEREIN";
      copy.append(name, role);
      chip.append(icon, copy);
      return chip;
    }

    function renderTracks(items, factory) {
      const viewportWidth = Math.max(window.innerWidth, wall.getBoundingClientRect().width);
      const estimatedChipSpan = 168;
      const minimumSegmentWidth = viewportWidth + 640;
      const repetitions = Math.max(
        2,
        Math.ceil(minimumSegmentWidth / Math.max(items.length * estimatedChipSpan, 1)),
      );

      tracks.forEach(function (track, rowIndex) {
        track.replaceChildren();
        const segment = document.createElement("div");
        segment.className = "supporter-segment";
        const itemCount = items.length * repetitions;
        Array.from({ length: itemCount }).forEach(function (_, index) {
          segment.append(factory(items[(index + rowIndex * 4) % items.length]));
        });
        const duplicate = segment.cloneNode(true);
        duplicate.setAttribute("aria-hidden", "true");
        duplicate.querySelectorAll("a").forEach(function (link) {
          link.tabIndex = -1;
        });
        track.append(segment, duplicate);
      });
    }

    renderTracks(technologies, createTechnologyChip);

    const owner = wall.dataset.githubOwner || "";
    const repo = wall.dataset.githubRepo || "";
    const threshold = Number(wall.dataset.stargazerThreshold || 30);
    if (!owner || !repo) return;

    fetch(`https://api.github.com/repos/${owner}/${repo}/stargazers?per_page=100`, {
      headers: { Accept: "application/vnd.github+json" },
    })
      .then(function (response) {
        if (!response.ok) throw new Error(`GitHub returned ${response.status}`);
        return response.json();
      })
      .then(function (users) {
        if (!Array.isArray(users) || users.length < threshold) return;
        renderTracks(users, createSupporterChip);
        wall.classList.add("is-supporter-mode");
        const kicker = wall.querySelector("[data-wall-kicker]");
        const status = wall.querySelector("[data-wall-status]");
        const title = wall.querySelector("[data-wall-title]");
        const description = wall.querySelector("[data-wall-description]");
        const link = wall.querySelector(".supporter-wall-link span");
        if (kicker) kicker.textContent = "PEOPLE WHO LIGHT IT UP";
        if (status) status.textContent = `${users.length}+ REAL STARS`;
        if (title) {
          title.dataset.zh = "这些人点亮了 Serein。";
          title.dataset.en = "These people lit up Serein.";
          title.textContent = english ? title.dataset.en : title.dataset.zh;
        }
        if (description) {
          description.dataset.zh = "点亮者名单与公开仓库的 GitHub Star 数据实时对应。";
          description.dataset.en = "The supporter wall reflects live GitHub Star data from the public repository.";
          description.textContent = english ? description.dataset.en : description.dataset.zh;
        }
        if (link) {
          link.dataset.zh = "去 GitHub 点亮它";
          link.dataset.en = "Light it up on GitHub";
          link.textContent = english ? link.dataset.en : link.dataset.zh;
        }
      })
      .catch(function (error) {
        console.warn("[serein] stargazer wall unavailable", error);
      });
  }

  setupSupporterWall();

  function setupSpotlightSurfaces() {
    document.querySelectorAll("[data-spotlight-surface]").forEach(function (surface) {
      let frame = 0;
      let latestEvent = null;
      surface.addEventListener("pointermove", function (event) {
        latestEvent = event;
        if (frame) return;
        frame = window.requestAnimationFrame(function () {
          const rect = surface.getBoundingClientRect();
          const x = ((latestEvent.clientX - rect.left) / rect.width) * 100;
          const y = ((latestEvent.clientY - rect.top) / rect.height) * 100;
          surface.style.setProperty("--spot-x", `${x.toFixed(2)}%`);
          surface.style.setProperty("--spot-y", `${y.toFixed(2)}%`);
          frame = 0;
        });
      }, { passive: true });
    });
  }

  setupSpotlightSurfaces();

  // Earlier drafts swept individual cards from right to left. That scattered
  // the motion across the page, so chapter-level vertical curtains now own
  // the transition for chapters 3 and 4 instead.
  const sweepTargets = [];
  sweepTargets.forEach(function (target) {
    // The regular reveal rule intentionally hides its targets. Remove it here
    // so a failed optional animation bundle never leaves editorial content blank.
    target.classList.remove("reveal");
    target.classList.add("sweep-reveal");
  });

  const revealItems = document.querySelectorAll(".reveal");
  const pendingSectionReveals = new Set();

  function revealOrQueue(item) {
    if (document.body.classList.contains("chapter-transitioning")) {
      pendingSectionReveals.add(item);
      return;
    }
    item.classList.add("visible");
  }

  function flushPendingSectionReveals() {
    pendingSectionReveals.forEach(function (item) {
      item.classList.add("visible");
    });
    pendingSectionReveals.clear();
  }

  if ("IntersectionObserver" in window) {
    const revealObserver = new IntersectionObserver(
      function (entries, observer) {
        entries.forEach(function (entry) {
          if (entry.isIntersecting) {
            revealOrQueue(entry.target);
            observer.unobserve(entry.target);
          }
        });
      },
      { threshold: 0.12 },
    );
    revealItems.forEach(function (item) {
      if (!item.classList.contains("sweep-reveal")) {
        revealObserver.observe(item);
      }
    });
  } else {
    revealItems.forEach(function (item) {
      item.classList.add("visible");
    });
  }

  function startAsciiRain() {
    const canvas = document.querySelector(".ascii-rain");
    if (!canvas || !canvas.getContext) return;
    const context = canvas.getContext("2d");
    if (!context) return;

    const glyphSize = 14;
    const trailLength = 16;
    const density = 24;
    const glyphs = Array.from("01<>/{}[]#SEREIN");
    const gap = glyphSize * (1 + (50 - density) / 12);
    const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
    let width = 0;
    let height = 0;
    let streams = [];
    let frame = 0;
    let previous = 0;
    let chapterTransitionPaused =
      document.body.classList.contains("chapter-transitioning");

    function randomGlyph() {
      return glyphs[Math.floor(Math.random() * glyphs.length)];
    }

    function makeStream(y) {
      return {
        y: y,
        rate: glyphSize * (3.2 + Math.random() * 2.4),
        release: height * (0.28 + Math.random() * 0.5),
        chars: Array.from({ length: trailLength }, randomGlyph),
      };
    }

    function layout() {
      const dpr = Math.min(2, window.devicePixelRatio || 1);
      width = window.innerWidth;
      height = window.innerHeight;
      canvas.width = Math.max(1, Math.round(width * dpr));
      canvas.height = Math.max(1, Math.round(height * dpr));
      context.setTransform(dpr, 0, 0, dpr, 0, 0);
      const columns = Math.max(1, Math.ceil(width / gap));
      streams = Array.from({ length: columns }, function (_, index) {
        return {
          x: index * gap + gap / 2,
          active: [makeStream(Math.random() * height)],
        };
      });
    }

    function draw(delta) {
      context.clearRect(0, 0, width, height);
      context.font = `${glyphSize}px ui-monospace, SFMono-Regular, Consolas, monospace`;
      context.textAlign = "center";
      context.textBaseline = "middle";

      streams.forEach(function (column) {
        column.active.forEach(function (stream) {
          stream.y += stream.rate * delta;
          if (Math.random() < 0.14) {
            stream.chars[Math.floor(Math.random() * stream.chars.length)] =
              randomGlyph();
          }
          for (let index = 0; index < trailLength; index += 1) {
            const y = stream.y - index * glyphSize;
            if (y < -glyphSize || y > height + glyphSize) continue;
            const strength =
              index === 0 ? 1 : 0.48 * (1 - index / trailLength);
            context.globalAlpha = strength;
            context.fillStyle = index === 0 ? "#df7255" : "#f2a68c";
            context.fillText(stream.chars[index], column.x, y);
          }
        });
        column.active = column.active.filter(function (stream) {
          return stream.y - trailLength * glyphSize <= height;
        });
        const newest = column.active[column.active.length - 1];
        if (!newest || newest.y >= newest.release) {
          column.active.push(makeStream(-trailLength * glyphSize));
        }
      });
      context.globalAlpha = 1;
    }

    function loop(time) {
      frame = 0;
      if (chapterTransitionPaused) {
        previous = 0;
        return;
      }
      const delta = previous
        ? Math.min((time - previous) / 1000, 0.05)
        : 1 / 60;
      previous = time;
      draw(reducedMotion.matches ? 0.18 : delta);
      if (!reducedMotion.matches) frame = window.requestAnimationFrame(loop);
    }

    layout();
    window.addEventListener("resize", layout, { passive: true });
    frame = window.requestAnimationFrame(loop);
    window.addEventListener("serein:chapter-transition", function (event) {
      chapterTransitionPaused = Boolean(event.detail?.active);
      window.cancelAnimationFrame(frame);
      frame = 0;
      previous = 0;
      if (!chapterTransitionPaused) {
        frame = window.requestAnimationFrame(loop);
      }
    });
    reducedMotion.addEventListener("change", function () {
      window.cancelAnimationFrame(frame);
      frame = 0;
      previous = 0;
      if (!chapterTransitionPaused) frame = window.requestAnimationFrame(loop);
    });
  }

  startAsciiRain();

  function setupWorkflowLoop() {
    const list = document.querySelector(".workflow-loop ol");
    if (!list) return;
    const facts = [
      {
        value: "83,347",
        labelZh: "行一方源码",
        labelEn: "first-party lines",
        detailZh: "2026-07-28 仓库快照：296 个源文件；已排除依赖、构建目录和生成 bundle。",
        detailEn: "Repository snapshot on 2026-07-28: 296 source files, excluding dependencies, build output, and generated bundles.",
      },
      {
        value: "296",
        labelZh: "源文件",
        labelEn: "source files",
        detailZh: "统计来自 git 已跟踪文件，只计算 Go、ArkTS、Node.js、Python、C++、HTML 与 CSS 等一方源码。",
        detailEn: "Counted from Git-tracked first-party Go, ArkTS, Node.js, Python, C++, HTML, CSS, and related source files.",
      },
      {
        value: "4",
        labelZh: "运行层",
        labelEn: "runtime layers",
        detailZh: "Go 服务端、ArkTS 鸿蒙 App、Node.js PTY relay、Python Hook 各守一层边界。",
        detailEn: "Go server, native ArkTS app, Node.js PTY relay, and Python Hook each own a distinct boundary.",
      },
      {
        value: "200ms",
        labelZh: "CLI 扫描",
        labelEn: "CLI scan",
        detailZh: "JSONL 监听器每 200ms 检查新增 CLI 事件；这是本地扫描节奏，不冒充手机端到端延迟。",
        detailEn: "The JSONL watcher checks for new CLI events every 200ms. This is a local scan cadence, not claimed as phone end-to-end latency.",
      },
      {
        value: "1s",
        labelZh: "授权检查",
        labelEn: "consent check",
        detailZh: "Windows Host 每秒检查一次待处理远程会话，设计目标是在 2 秒内接住授权请求；网络时间另计。",
        detailEn: "The Windows Host checks pending remote sessions every second, targeting consent pickup within two seconds; network time is separate.",
      },
      {
        value: "20s",
        labelZh: "状态心跳",
        labelEn: "status heartbeat",
        detailZh: "普通状态每 20 秒静默上报；启动、停止等状态变化会立即推送，不必等下一次心跳。",
        detailEn: "Normal status reports every 20 seconds; start and stop transitions push immediately instead of waiting for the next heartbeat.",
      },
      {
        value: "25s",
        labelZh: "WS 保活",
        labelEn: "WS keepalive",
        detailZh: "终端 relay 与远控信令都使用 25 秒级心跳，避免 NAT 或代理把安静连接误判为失效。",
        detailEn: "Terminal relay and remote signaling use a 25-second keepalive to stop NATs or proxies dropping quiet connections.",
      },
      {
        value: "30s",
        labelZh: "Host 心跳",
        labelEn: "Host heartbeat",
        detailZh: "被控端每 30 秒刷新在线与能力状态；失联判断与会话状态机独立处理。",
        detailEn: "The controlled Host refreshes online and capability state every 30 seconds, with disconnect handling owned by the session state machine.",
      },
      {
        value: "60/10s",
        labelZh: "审批补拉",
        labelEn: "approval fallback",
        detailZh: "ntfy WebSocket 在线时每 60 秒低频核对；断线时切换为 10 秒 HTTP 补拉，避免单通道失效。",
        detailEn: "With ntfy WebSocket alive, HTTP verifies every 60 seconds; after disconnect it falls back to a 10-second poll.",
      },
      {
        value: "AES-256",
        labelZh: "GCM 会话",
        labelEn: "GCM session",
        detailZh: "终端输入与输出使用 AES-256-GCM；后端只透传密文，不读取会话正文。",
        detailEn: "Terminal input and output use AES-256-GCM. The backend forwards ciphertext without reading session content.",
      },
      {
        value: "200k",
        labelZh: "PIN 派生",
        labelEn: "PIN derivation",
        detailZh: "本地 PIN 使用 PBKDF2-SHA256 进行 20 万次迭代派生，并保留旧格式迁移兼容。",
        detailEn: "Local PIN protection uses 200,000 PBKDF2-SHA256 rounds while retaining migration support for older records.",
      },
      {
        value: "15fps",
        labelZh: "远控帧率",
        labelEn: "remote FPS",
        detailZh: "当前 Windows Host 默认以 15 FPS、H.264 低延迟路径工作；实际画质由设备和网络共同决定。",
        detailEn: "The current Windows Host defaults to a 15 FPS low-latency H.264 path; actual quality still depends on device and network.",
      },
      {
        value: "2Mbps",
        labelZh: "远控码率",
        labelEn: "remote bitrate",
        detailZh: "当前流媒体默认目标码率为 2 Mbps；WebRTC 负责拥塞控制、弱网调整与 P2P / TURN 协商。",
        detailEn: "The current media target is 2 Mbps, while WebRTC owns congestion control, network adaptation, and P2P or TURN negotiation.",
      },
      {
        value: "1 台",
        labelZh: "设备绑定",
        labelEn: "device binding",
        detailZh: "同一套部署只允许一个当前绑定手机；解绑后，另一台设备才能重新绑定。",
        detailEn: "One deployment accepts one currently paired phone. A different device can bind only after the first is unpaired.",
      },
      {
        value: "3",
        labelZh: "数据路径",
        labelEn: "data paths",
        detailZh: "PTY / WebSocket 负责会话，ntfy 负责后台提醒，WebRTC / DataChannel 负责画面与触控。",
        detailEn: "PTY and WebSocket carry sessions, ntfy carries background alerts, and WebRTC with DataChannel carries video and input.",
      },
      {
        value: "25,087",
        labelZh: "Go 服务端",
        labelEn: "Go server",
        detailZh: "Go + chi + SQLite 处理鉴权、审批、状态机和长连接，部署时不需要拼装一堆运行时服务。",
        detailEn: "Go, chi, and SQLite handle auth, approvals, state machines, and long connections without a stack of runtime services.",
      },
      {
        value: "24,166",
        labelZh: "ArkTS 原生",
        labelEn: "native ArkTS",
        detailZh: "ArkTS 直接接入系统通知、后台任务、键盘、手势和设备安全存储，不是网页套壳。",
        detailEn: "ArkTS directly reaches notifications, background tasks, keyboard, gestures, and secure device storage instead of wrapping a web page.",
      },
      {
        value: "5,767",
        labelZh: "Node Relay",
        labelEn: "Node relay",
        detailZh: "Node.js 贴着 Claude Code 与 Codex CLI 运行，负责 PTY、结构化事件和双向 WebSocket。",
        detailEn: "Node.js runs beside Claude Code and Codex CLI, owning PTY, structured events, and the bidirectional WebSocket.",
      },
      {
        value: "14,070",
        labelZh: "Python Hook",
        labelEn: "Python Hook",
        detailZh: "Python Hook 在本机完成风险分级；审批基础设施异常时，敏感操作默认拒绝。",
        detailEn: "The Python Hook grades risk locally, and sensitive actions fail closed when approval infrastructure is unavailable.",
      },
    ];

    const hexLineWidths = [54, 68, 82, 94, 94, 82, 68, 54];
    const hexMeasureCanvas = document.createElement("canvas");
    const hexMeasureContext = hexMeasureCanvas.getContext("2d");

    function detailTokens(text) {
      if (typeof Intl === "undefined" || !Intl.Segmenter) {
        return Array.from(text.trim());
      }
      return Array.from(
        new Intl.Segmenter(english ? "en" : "zh-CN", {
          granularity: "word",
        }).segment(text.trim()),
        function (part) {
          return part.segment;
        },
      );
    }

    function wrapHexDetail(text, copy) {
      const queue = detailTokens(text);
      const lines = [];
      const style = window.getComputedStyle(copy);
      const copyWidth =
        copy.getBoundingClientRect().width ||
        copy.closest(".workflow-loop-node")?.getBoundingClientRect().width ||
        120;
      if (hexMeasureContext) hexMeasureContext.font = style.font;
      const measure = function (value) {
        if (!hexMeasureContext) return Array.from(value).length * 8;
        return hexMeasureContext.measureText(value).width;
      };

      hexLineWidths.forEach(function (widthPercent) {
        // Leave two physical pixels of breathing room so antialiasing never
        // touches the clipped diagonal edge of the regular hexagon.
        const availableWidth = Math.max(1, copyWidth * (widthPercent / 100) - 2);
        let line = "";
        while (queue.length && /^\s+$/.test(queue[0])) queue.shift();
        while (queue.length) {
          const token = queue[0];
          if (measure(line + token) <= availableWidth) {
            line += token;
            queue.shift();
            continue;
          }
          if (!line) {
            const characters = Array.from(token);
            let consumed = "";
            while (
              characters.length &&
              measure(consumed + characters[0]) <= availableWidth
            ) {
              const character = characters.shift();
              consumed += character;
            }
            line = consumed;
            if (characters.length) queue[0] = characters.join("");
            else queue.shift();
          }
          break;
        }
        lines.push(line.trim());
      });
      if (queue.length) {
        const lastIndex = lines.length - 1;
        let finalLine = lines[lastIndex];
        const finalWidth =
          copyWidth * (hexLineWidths[lastIndex] / 100) - 2;
        while (finalLine.length && measure(`${finalLine}…`) > finalWidth) {
          finalLine = Array.from(finalLine).slice(0, -1).join("");
        }
        lines[lastIndex] = `${finalLine.trim()}…`;
      }
      return lines;
    }

    layoutHexDetails = function () {
      document.querySelectorAll(".workflow-loop-detail p").forEach(function (copy) {
        const source = english ? copy.dataset.en : copy.dataset.zh;
        const lines = wrapHexDetail(source || copy.textContent || "", copy);
        copy.replaceChildren(
          ...lines.map(function (line, index) {
            const span = document.createElement("span");
            span.className = "workflow-hex-line";
            span.style.setProperty("--hex-line-width", `${hexLineWidths[index]}%`);
            span.textContent = line || "\u00a0";
            return span;
          }),
        );
      });
    };

    let hexLayoutFrame = 0;
    window.addEventListener(
      "resize",
      function () {
        window.cancelAnimationFrame(hexLayoutFrame);
        hexLayoutFrame = window.requestAnimationFrame(layoutHexDetails);
      },
      { passive: true },
    );

    function createFactNode(fact, index) {
      const node = document.createElement("li");
      node.className = "workflow-loop-node workflow-loop-fact";
      const button = document.createElement("button");
      button.className = "workflow-loop-card";
      button.type = "button";
      button.setAttribute("aria-expanded", "false");
      const kicker = document.createElement("b");
      kicker.textContent = `SIGNAL / ${String(index + 1).padStart(2, "0")}`;
      const value = document.createElement("strong");
      value.textContent = fact.value;
      const label = document.createElement("span");
      label.dataset.zh = fact.labelZh;
      label.dataset.en = fact.labelEn;
      label.textContent = fact.labelZh;
      button.append(kicker, value, label);
      const detail = document.createElement("div");
      detail.className = "workflow-loop-detail";
      const copy = document.createElement("p");
      copy.dataset.zh = fact.detailZh;
      copy.dataset.en = fact.detailEn;
      copy.textContent = fact.detailZh;
      detail.append(copy);
      node.append(button, detail);
      return node;
    }

    const factNodes = facts.map(createFactNode);
    const contentNodes = [
      factNodes[0],
      factNodes[3],
      factNodes[9],
      factNodes[1],
      factNodes[5],
      factNodes[6],
      factNodes[7],
      factNodes[10],
      factNodes[11],
      factNodes[12],
    ];
    const honeycombColumns = 7;
    const honeycombRows = 4;
    // Flat-top regular hexagons interlock by overlapping adjacent columns by
    // one quarter-cell. Odd columns move down half a cell; the deliberately
    // incomplete outer columns keep the cluster cropped and asymmetric.
    const visibleRowsByColumn = [
      [1, 2],
      [0, 1, 2, 3],
      [0, 1, 2, 3],
      [0, 1, 2, 3],
      [0, 1, 2],
      [0, 1, 2, 3],
      [1, 2, 3],
    ];
    const visibleSlots = new Set();
    visibleRowsByColumn.forEach(function (rows, column) {
      rows.forEach(function (row) {
        visibleSlots.add(row * honeycombColumns + column);
      });
    });
    const activeSlots = [2, 5, 8, 11, 14, 17, 19, 22, 24, 27];
    const contentBySlot = new Map();
    activeSlots.forEach(function (slot, index) {
      if (contentNodes[index]) contentBySlot.set(slot, contentNodes[index]);
    });

    list.replaceChildren();
    for (let slot = 0; slot < honeycombColumns * honeycombRows; slot += 1) {
      if (!visibleSlots.has(slot)) continue;
      const row = Math.floor(slot / honeycombColumns);
      const column = slot % honeycombColumns;
      const node = contentBySlot.get(slot) || document.createElement("li");
      node.classList.add("workflow-loop-cell");
      const totalWidth = 1 + (honeycombColumns - 1) * 0.75;
      const totalHeight = honeycombRows + 0.5;
      node.style.setProperty(
        "--hex-left",
        `${((column * 0.75) / totalWidth) * 100}%`,
      );
      node.style.setProperty(
        "--hex-top",
        `${((row + (column % 2) * 0.5) / totalHeight) * 100}%`,
      );
      if (!contentBySlot.has(slot)) {
        node.className = "workflow-loop-cell workflow-loop-ghost";
        node.setAttribute("aria-hidden", "true");
      } else {
        node.style.setProperty("--loop-surface", "#3f4650");
        node.style.setProperty("--loop-pop", "#f47f61");
        node.style.setProperty("--loop-pop-ink", "#211713");
      }
      list.append(node);
    }
    layoutHexDetails();

    const nodes = Array.from(list.querySelectorAll(".workflow-loop-node"));
    if (!nodes.length) return;

    function activate(node) {
      nodes.forEach(function (item) {
        const isActive = item === node;
        item.classList.toggle("is-active", isActive);
        const button = item.querySelector(".workflow-loop-card");
        if (button) button.setAttribute("aria-expanded", String(isActive));
        const detail = item.querySelector(".workflow-loop-detail");
        if (detail) {
          detail.setAttribute("aria-hidden", String(!isActive));
        }
      });
    }

    nodes.forEach(function (node) {
      const button = node.querySelector(".workflow-loop-card");
      if (!button) return;
      button.addEventListener("click", function () {
        activate(node.classList.contains("is-active") ? null : node);
      });
      const detail = node.querySelector(".workflow-loop-detail");
      if (!detail) return;
      detail.setAttribute("role", "button");
      detail.setAttribute("tabindex", "0");
      detail.setAttribute("aria-hidden", "true");
      detail.setAttribute("aria-label", "Close workflow detail");
      detail.addEventListener("click", function () {
        activate(null);
      });
      detail.addEventListener("keydown", function (event) {
        if (event.key === "Enter" || event.key === " ") {
          event.preventDefault();
          activate(null);
        }
      });
    });
    activate(null);
  }

  setupWorkflowLoop();

  if (!window.gsap) {
    // Keep all editorial sections usable when the optional animation bundle
    // is unavailable (offline preview, strict CSP, or an interrupted cache).
    sweepTargets.forEach(function (target) { target.classList.add("visible"); });
    return;
  }
  if (window.ScrollTrigger) {
    gsap.registerPlugin(ScrollTrigger);
  }

  let curtainAnimations = [];
  const pendingCurtainReveals = new Set();

  function playCurtainRevealOrQueue(timeline) {
    if (document.body.classList.contains("chapter-transitioning")) {
      pendingCurtainReveals.add(timeline);
      return;
    }
    timeline.play(0);
  }

  function flushPendingCurtainReveals() {
    pendingCurtainReveals.forEach(function (timeline) {
      timeline.play(0);
    });
    pendingCurtainReveals.clear();
  }

  function setupCurtainReveals(replayCurrent) {
    curtainAnimations.forEach(function (animation) {
      pendingCurtainReveals.delete(animation);
      if (animation.scrollTrigger) animation.scrollTrigger.kill();
      animation.kill();
    });
    curtainAnimations = [];

    const headings = Array.from(
      document.querySelectorAll(
        ".hero h1, .section-intro h2, .self-host-copy h2",
      ),
    );

    headings.forEach(function (heading, headingIndex) {
      const source =
        (english ? heading.dataset.en : heading.dataset.zh) ||
        heading.innerHTML;
      const lines = source
        .split(/<br\s*\/?>/i)
        .map(function (line) {
          return (
            '<span class="curtain-line"><span class="curtain-text">' +
            line +
            '</span><span class="curtain-wipe" aria-hidden="true"></span></span>'
          );
        })
        .join("");

      heading.classList.add("curtain-heading");
      heading.innerHTML = lines;
      const textLines = Array.from(heading.querySelectorAll(".curtain-text"));
      const wipes = Array.from(heading.querySelectorAll(".curtain-wipe"));

      if (prefersReducedMotion.matches) {
        gsap.set(textLines, { yPercent: 0 });
        gsap.set(wipes, { scaleX: 0 });
        return;
      }

      gsap.set(textLines, { yPercent: 118 });
      gsap.set(wipes, { scaleX: 0, transformOrigin: "left center" });

      const timeline = gsap.timeline({
        paused: true,
        defaults: { ease: "power3.inOut" },
      });
      textLines.forEach(function (line, lineIndex) {
        const start = lineIndex * 0.17;
        timeline
          .to(
            wipes[lineIndex],
            {
              scaleX: 1,
              duration: 0.42,
              transformOrigin: "left center",
            },
            start,
          )
          .set(line, { yPercent: 0 }, start + 0.34)
          .to(
            wipes[lineIndex],
            {
              scaleX: 0,
              duration: 0.5,
              transformOrigin: "right center",
            },
            start + 0.37,
          );
      });
      curtainAnimations.push(timeline);

      const rect = heading.getBoundingClientRect();
      const isCurrent = rect.top < window.innerHeight * 0.82 && rect.bottom > 0;
      if (headingIndex === 0 || (replayCurrent && isCurrent)) {
        timeline.play(0);
      } else if (window.ScrollTrigger) {
        ScrollTrigger.create({
          trigger: heading,
          start: "top 78%",
          once: true,
          onEnter: function () {
            playCurtainRevealOrQueue(timeline);
          },
        });
      } else {
        timeline.play(0);
      }
    });
  }

  function setupHorizontalScroll() {
    const stage = document.querySelector("[data-horizontal-stage]");
    const horizontalTrack = document.querySelector("[data-horizontal-track]");
    if (!stage || !horizontalTrack || !window.ScrollTrigger) return;

    gsap.matchMedia().add(
      {
        desktop: "(min-width: 961px)",
        reduceMotion: "(prefers-reduced-motion: reduce)",
      },
      function (context) {
        const conditions = context.conditions || {};
        if (!conditions.desktop || conditions.reduceMotion) {
          gsap.set(horizontalTrack, { clearProps: "transform" });
          return undefined;
        }

        const distance = function () {
          return Math.max(0, horizontalTrack.scrollWidth - window.innerWidth);
        };
        const cardCount = horizontalTrack.querySelectorAll(
          "[data-feature-option]",
        ).length;
        const scrollTween = gsap.to(horizontalTrack, {
          x: function () {
            return -distance();
          },
          ease: "none",
          scrollTrigger: {
            id: "serein-horizontal-capabilities",
            trigger: stage,
            start: "top 12%",
            end: function () {
              return "+=" + Math.max(1800, distance() * 1.12);
            },
            pin: true,
            scrub: 0.85,
            anticipatePin: 1,
            invalidateOnRefresh: true,
            snap:
              cardCount > 1
                ? {
                    snapTo: 1 / (cardCount - 1),
                    duration: { min: 0.18, max: 0.48 },
                    delay: 0.06,
                    ease: "power1.inOut",
                  }
                : false,
          },
        });

        return function () {
          if (scrollTween.scrollTrigger) scrollTween.scrollTrigger.kill();
          scrollTween.kill();
          gsap.set(horizontalTrack, { clearProps: "transform" });
        };
      },
    );
  }

  function setupChapterCurtains() {
    if (prefersReducedMotion.matches) return;
    const chapters = Array.from(document.querySelectorAll("main > .chapter"));
    if (chapters.length !== 4) return;

    const curtain = document.createElement("div");
    curtain.className = "chapter-curtain";
    curtain.setAttribute("aria-hidden", "true");
    curtain.innerHTML =
      '<canvas class="chapter-curtain-canvas" role="presentation"></canvas>';
    document.body.append(curtain);
    const curtainCanvas = curtain.querySelector(".chapter-curtain-canvas");
    const curtainContext = curtainCanvas.getContext("2d", {
      alpha: true,
      desynchronized: true,
    });
    const curtainColours = ["#1d1131", "#ff5a00", "#facc4f"];
    let curtainWidth = 1;
    let curtainHeight = 1;
    let curtainDpr = 1;
    let curtainFromBottom = false;
    let playing = false;
    let wheelGestureArmed = true;
    let wheelGestureDelta = 0;
    let wheelGestureReset = 0;

    function scrollingElement() {
      return document.scrollingElement || document.documentElement;
    }

    function readScrollTop() {
      return scrollingElement().scrollTop || 0;
    }

    function setScrollTop(value) {
      scrollingElement().scrollTop = Math.round(value);
    }

    function chapterTop(index) {
      const currentScrollTop = readScrollTop();
      return Math.round(
        chapters[index].getBoundingClientRect().top + currentScrollTop,
      );
    }

    function setChapterTransitionState(active) {
      document.body.classList.toggle("chapter-transitioning", active);
      document.documentElement.classList.toggle("chapter-transitioning", active);
      window.dispatchEvent(
        new CustomEvent("serein:chapter-transition", {
          detail: { active: active },
        }),
      );
    }

    // Elecctro's public curtains.js uses three staggered SVG paths. That works
    // across a real navigation because exit and entry are separate documents,
    // but resetting those paths between two in-page chapters produces a flash.
    // Here the same idea is rendered as three contiguous ribbons travelling in
    // one direction. Four ordered boundaries generate the three fills, so the
    // colours cannot cross or expose a full-screen single-colour frame.
    const curtainState = {
      edge0: -160,
      edge1: -160,
      edge2: -160,
      edge3: -160,
      curve: 0.7,
      exit: 0,
    };
    const curtainPerfEnabled = new URLSearchParams(window.location.search).has(
      "curtainPerf",
    );
    let curtainPerfPrevious = 0;
    let curtainPerfGaps = [];
    const edgeStrength = [1, 0.9, 0.8, 0.72];

    function roundPathNumber(value) {
      return Math.round(value * 100) / 100;
    }

    function boundaryGeometry(edge, strength) {
      const y = roundPathNumber(edge + curtainState.exit);
      const amplitude = 43 * curtainState.curve * strength;
      return {
        y: y,
        peak: roundPathNumber(y + amplitude),
        shoulder: roundPathNumber(y + amplitude * 0.94),
        firstControl: roundPathNumber(y + amplitude * 0.1),
        lastControl: roundPathNumber(y + amplitude * 0.08),
      };
    }

    function resizeCurtainCanvas() {
      curtainWidth = Math.max(1, window.innerWidth);
      curtainHeight = Math.max(1, window.innerHeight);
      // The curtain contains broad solid fields rather than text or fine
      // lines. Render it below CSS-pixel resolution and let the compositor
      // scale it once; on 2K displays this removes roughly half of the
      // per-frame fill work while the long bezier edges remain visually
      // smooth.
      curtainDpr = 0.72;
      curtainCanvas.width = Math.round(curtainWidth * curtainDpr);
      curtainCanvas.height = Math.round(curtainHeight * curtainDpr);
      curtainCanvas.style.width = `${curtainWidth}px`;
      curtainCanvas.style.height = `${curtainHeight}px`;
    }

    function traceForwardBoundary(geometry) {
      curtainContext.moveTo(0, geometry.y);
      curtainContext.bezierCurveTo(
        18,
        geometry.firstControl,
        31,
        geometry.peak,
        50,
        geometry.peak,
      );
      curtainContext.bezierCurveTo(
        68,
        geometry.shoulder,
        82,
        geometry.lastControl,
        100,
        geometry.y,
      );
    }

    function traceReverseBoundary(geometry) {
      curtainContext.bezierCurveTo(
        82,
        geometry.lastControl,
        68,
        geometry.shoulder,
        50,
        geometry.peak,
      );
      curtainContext.bezierCurveTo(
        31,
        geometry.peak,
        18,
        geometry.firstControl,
        0,
        geometry.y,
      );
    }

    function drawRibbon(upperGeometry, lowerGeometry, colour) {
      curtainContext.beginPath();
      traceForwardBoundary(upperGeometry);
      curtainContext.lineTo(100, lowerGeometry.y);
      traceReverseBoundary(lowerGeometry);
      curtainContext.closePath();
      curtainContext.fillStyle = colour;
      curtainContext.fill();
    }

    function renderCurtain() {
      if (curtainPerfEnabled) {
        const now = window.performance.now();
        if (curtainPerfPrevious) curtainPerfGaps.push(now - curtainPerfPrevious);
        curtainPerfPrevious = now;
      }
      // DOM order is ink, coral, sun. Visually they form the leading,
      // middle and trailing parts of one train.
      const geometries = edgeStrength.map(function (strength, index) {
        return boundaryGeometry(curtainState[`edge${index}`], strength);
      });
      curtainContext.setTransform(curtainDpr, 0, 0, curtainDpr, 0, 0);
      curtainContext.clearRect(0, 0, curtainWidth, curtainHeight);
      curtainContext.save();
      curtainContext.scale(curtainWidth / 100, curtainHeight / 100);
      if (curtainFromBottom) {
        curtainContext.translate(0, 100);
        curtainContext.scale(1, -1);
      }
      drawRibbon(geometries[1], geometries[0], curtainColours[0]);
      drawRibbon(geometries[2], geometries[1], curtainColours[1]);
      drawRibbon(geometries[3], geometries[2], curtainColours[2]);
      curtainContext.restore();
    }

    function continuousChaseEase(waypointProgress, waypointValue) {
      const leftSlope = waypointValue / waypointProgress;
      const rightSlope =
        (1 - waypointValue) / (1 - waypointProgress);
      // The harmonic mean gives both halves one shared, monotone velocity at
      // the waypoint. This avoids the old "ease to zero, then start again"
      // hitch while preserving the same chase positions and finishing order.
      const middleSlope =
        (2 * leftSlope * rightSlope) / (leftSlope + rightSlope);

      function hermite(t, from, to, fromSlope, toSlope, span) {
        const t2 = t * t;
        const t3 = t2 * t;
        return (
          (2 * t3 - 3 * t2 + 1) * from +
          (t3 - 2 * t2 + t) * fromSlope * span +
          (-2 * t3 + 3 * t2) * to +
          (t3 - t2) * toSlope * span
        );
      }

      return function (progress) {
        if (progress <= waypointProgress) {
          return hermite(
            progress / waypointProgress,
            0,
            waypointValue,
            0,
            middleSlope,
            waypointProgress,
          );
        }
        const span = 1 - waypointProgress;
        return hermite(
          (progress - waypointProgress) / span,
          waypointValue,
          1,
          middleSlope,
          0,
          span,
        );
      };
    }

    resizeCurtainCanvas();
    renderCurtain();
    window.addEventListener("resize", resizeCurtainCanvas, { passive: true });

    function chapterIndexAtViewport() {
      let closestIndex = 0;
      let closestDistance = Infinity;
      chapters.forEach(function (chapter, index) {
        const distance = Math.abs(chapter.getBoundingClientRect().top);
        if (distance < closestDistance) {
          closestDistance = distance;
          closestIndex = index;
        }
      });
      return closestIndex;
    }

    function finishChapterMove(targetTop, previousScrollBehavior) {
      setScrollTop(targetTop);
      setChapterTransitionState(false);
      document.documentElement.style.scrollBehavior = previousScrollBehavior;
      window.requestAnimationFrame(function () {
        // Re-assert the exact boundary once after scroll-snap is restored.
        // This is a single settled write, not a per-frame correction loop.
        setScrollTop(targetTop);
        playing = false;
        flushPendingSectionReveals();
        flushPendingCurtainReveals();
      });
    }

    function playPlainChapter(targetIndex) {
      if (playing) return;
      playing = true;
      const targetTop = chapterTop(targetIndex);
      const scrollState = { y: readScrollTop() };
      const previousScrollBehavior =
        document.documentElement.style.scrollBehavior;
      setChapterTransitionState(true);
      document.documentElement.style.scrollBehavior = "auto";
      gsap.to(scrollState, {
        y: targetTop,
        duration: 0.72,
        ease: "power2.inOut",
        overwrite: true,
        onUpdate: function () {
          setScrollTop(scrollState.y);
        },
        onComplete: function () {
          finishChapterMove(targetTop, previousScrollBehavior);
        },
      });
    }

    function playCurtain(sourceIndex, targetIndex, direction) {
      if (playing) return;
      playing = true;
      // Read layout before any animation write. Reading offsetTop inside the
      // timeline callback forced a synchronous full-page layout at the exact
      // midpoint of the morph and was the visible one-frame hitch.
      const sourceTop = chapterTop(sourceIndex);
      const targetTop = chapterTop(targetIndex);
      const orbitWasRunning = Boolean(orbitTimeline && !orbitTimeline.paused());
      if (orbitWasRunning) orbitTimeline.pause();
      setChapterTransitionState(true);
      gsap.killTweensOf([curtain, curtainState]);
      gsap.set(curtain, { autoAlpha: 1 });
      const fromBottom = direction < 0;
      curtainFromBottom = fromBottom;
      const previousScrollBehavior = document.documentElement.style.scrollBehavior;
      document.documentElement.style.scrollBehavior = "auto";
      // Freeze the exact frame the user is already looking at. The old code
      // snapped back to sourceTop here; after a native smooth/snap scroll that
      // correction was visible as a one-frame downward hitch. Writing the
      // current position cancels residual native scrolling without a jump.
      setScrollTop(sourceTop);
      Object.assign(curtainState, {
        edge0: -160,
        edge1: -160,
        edge2: -160,
        edge3: -160,
        curve: 0.7,
        exit: 0,
      });
      curtainPerfPrevious = 0;
      curtainPerfGaps = [];
      renderCurtain();

      const timeline = gsap.timeline({
        // A timeline-level callback runs once per GSAP tick. Putting onUpdate
        // in defaults made every overlapping child tween rewrite all three SVG
        // paths, sometimes eight or nine times in one animation frame.
        onUpdate: renderCurtain,
        onComplete: function () {
          if (curtainPerfEnabled && curtainPerfGaps.length) {
            const ordered = curtainPerfGaps.slice().sort(function (a, b) {
              return a - b;
            });
            const average =
              curtainPerfGaps.reduce(function (sum, gap) {
                return sum + gap;
              }, 0) / curtainPerfGaps.length;
            console.info(
              "[serein-curtain-perf]",
              JSON.stringify({
                direction: direction > 0 ? "down" : "up",
                frames: curtainPerfGaps.length,
                average: Math.round(average * 100) / 100,
                p95:
                  Math.round(
                    ordered[Math.floor(ordered.length * 0.95)] * 100,
                  ) / 100,
                max:
                  Math.round(ordered[ordered.length - 1] * 100) / 100,
                over24: curtainPerfGaps.filter(function (gap) {
                  return gap > 24;
                }).length,
                over34: curtainPerfGaps.filter(function (gap) {
                  return gap > 34;
                }).length,
              }),
            );
          }
          // Finish on the exact chapter boundary while native snap is still
          // disabled. Re-enabling snap from a fractional scroll position made
          // the browser perform one more correction after the curtain, which
          // looked like the page slipping down after the animation.
          setScrollTop(targetTop);
          setChapterTransitionState(false);
          document.documentElement.style.scrollBehavior = previousScrollBehavior;
          gsap.set(curtain, { autoAlpha: 0 });
          if (orbitWasRunning && orbitTimeline) orbitTimeline.resume();
          window.requestAnimationFrame(function () {
            setScrollTop(targetTop);
            playing = false;
            // Entering a fresh chapter may start headline and content
            // reveals. Start them only after the fixed SVG layer and the
            // snap lock have both settled.
            flushPendingSectionReveals();
            flushPendingCurtainReveals();
          });
        },
      });
      timeline
        .addLabel("travel")
        .to(curtainState, {
          curve: 1,
          duration: 0.64,
          ease: "sine.out",
        }, "travel")
        // The front starts first. Each following boundary starts later but
        // moves faster, creating a visible chase without ever overtaking.
        // Each edge now travels in one continuous tween. The custom monotone
        // ease passes through the old chase waypoint without dropping its
        // velocity to zero, which was the remaining mid-transition pause.
        .to(curtainState, {
          edge0: 110,
          duration: 1.65,
          ease: continuousChaseEase(
            1.15 / 1.65,
            (103 + 160) / (110 + 160),
          ),
        }, "travel")
        .to(curtainState, {
          edge1: 106,
          duration: 1.31,
          ease: continuousChaseEase(
            0.88 / 1.31,
            (65 + 160) / (106 + 160),
          ),
        }, "travel+=0.34")
        .to(curtainState, {
          edge2: 102,
          duration: 1.03,
          ease: continuousChaseEase(
            0.64 / 1.03,
            (10 + 160) / (102 + 160),
          ),
        }, "travel+=0.62")
        .to(curtainState, {
          edge3: 98,
          duration: 0.77,
          ease: continuousChaseEase(
            0.35 / 0.77,
            (-60 + 160) / (98 + 160),
          ),
        }, "travel+=0.88");
      // The trailing colours keep catching the leaders while the next page
      // appears; no edge stops, resets, or starts a second tween.

      timeline.addLabel("swap", 1.23);
      timeline
        .call(
          function () {
            setScrollTop(targetTop);
          },
          null,
          "swap",
        )
        // Only the last few viewport units flatten. The three narrow straight
        // strips then leave together, so the ending remains visible but brief.
        .to(curtainState, {
          curve: 0,
          duration: 0.2,
          ease: "sine.inOut",
        }, "travel+=1.48")
        .to(curtainState, {
          // As the 43-unit crest flattens, move the whole train forward by
          // the same distance. The centre therefore never springs backwards;
          // flattening and leaving become one continuous piece of motion.
          exit: 61,
          duration: 0.48,
          ease: continuousChaseEase(0.2 / 0.48, 43 / 61),
        }, "travel+=1.48");
    }

    window.addEventListener("wheel", function (event) {
      if (window.innerWidth < 961) {
        return;
      }
      // Treat the event stream from one physical wheel/trackpad gesture as a
      // single chapter command. Small deltas are accumulated instead of being
      // allowed to move the native page, and inertial tail events cannot start
      // a second chapter after the first animation has completed.
      event.preventDefault();
      window.clearTimeout(wheelGestureReset);
      wheelGestureReset = window.setTimeout(function () {
        wheelGestureArmed = true;
        wheelGestureDelta = 0;
      }, 180);
      if (playing || !wheelGestureArmed) return;
      wheelGestureDelta += event.deltaY;
      if (Math.abs(wheelGestureDelta) < 18) return;
      const currentIndex = chapterIndexAtViewport();
      const direction = wheelGestureDelta > 0 ? 1 : -1;
      wheelGestureArmed = false;
      wheelGestureDelta = 0;
      const targetIndex = currentIndex + direction;
      if (targetIndex < 0 || targetIndex >= chapters.length) return;
      // Every wheel gesture owns exactly one chapter. The first pair uses a
      // plain eased move; entering/leaving chapters three and four adds the
      // deliberate curtain on top of the same deterministic navigation.
      const needsCurtain =
        (direction > 0 && targetIndex >= 2 && targetIndex < chapters.length) ||
        (direction < 0 && currentIndex >= 2 && targetIndex >= 1);
      if (needsCurtain) {
        playCurtain(currentIndex, targetIndex, direction);
      } else {
        playPlainChapter(targetIndex);
      }
    }, { passive: false });
  }

  const gallery = document.querySelector(".hero-gallery");
  const track = document.querySelector(".orbit-track");
  const cards = track ? Array.from(track.querySelectorAll(".orbit-card")) : [];
  cards.forEach(function (card) {
    const front = card.querySelector("img");
    if (!front) return;
    const back = front.cloneNode();
    back.classList.add("orbit-card-back");
    back.alt = "";
    back.setAttribute("aria-hidden", "true");
    card.append(back);
  });
  const toggle = document.querySelector("[data-gallery-toggle]");
  const featureLab = document.querySelector("[data-feature-lab]");
  const featureOptions = Array.from(
    document.querySelectorAll("[data-feature-option]"),
  );
  const featureReplay = document.querySelector("[data-feature-replay]");
  const prefersReducedMotion = window.matchMedia(
    "(prefers-reduced-motion: reduce)",
  );
  let orbitTimeline;
  let activeFeature = null;
  function featureText(option, field) {
    return option.getAttribute(
      "data-feature-" + field + "-" + (english ? "en" : "zh"),
    );
  }

  function syncFeatureLabLanguage() {
    if (!featureLab || !activeFeature) return;
    const title = featureLab.querySelector("[data-feature-title]");
    const copy = featureLab.querySelector("[data-feature-copy]");
    const status = featureLab.querySelector("[data-feature-status]");
    if (title) title.textContent = featureText(activeFeature, "title");
    if (copy) copy.textContent = featureText(activeFeature, "copy");
    if (status) status.textContent = featureText(activeFeature, "status");
  }

  function replayFeatureLab() {
    if (!featureLab || prefersReducedMotion.matches) return;
    const scan = featureLab.querySelector(".radar-scan");
    const core = featureLab.querySelector(".radar-core");
    const copy = featureLab.querySelector(".playground-copy");
    const state = featureLab.querySelector(".playground-state");
    gsap.killTweensOf([scan, core, copy, state]);
    gsap
      .timeline({ defaults: { ease: "power3.out" } })
      .fromTo(
        scan,
        { autoAlpha: 0.18, rotation: -28 },
        { autoAlpha: 1, rotation: 332, duration: 0.88 },
      )
      .to(scan, { autoAlpha: 0.25, duration: 0.2 })
      .fromTo(
        core,
        { scale: 0.82 },
        { scale: 1.42, duration: 0.24, yoyo: true, repeat: 1 },
        0,
      )
      .fromTo(
        copy,
        { autoAlpha: 0.35, y: 11 },
        { autoAlpha: 1, y: 0, duration: 0.42 },
        0.08,
      )
      .fromTo(
        state,
        { autoAlpha: 0.45 },
        { autoAlpha: 1, duration: 0.36 },
        0.16,
      );
  }

  function selectFeature(option, shouldAnimate) {
    if (!featureLab || !option) return;
    activeFeature = option;
    featureOptions.forEach(function (item) {
      const selected = item === option;
      item.classList.toggle("is-active", selected);
      item.setAttribute("aria-pressed", String(selected));
    });
    featureLab.dataset.mode = option.dataset.featureKey || "terminal";
    const index = featureLab.querySelector("[data-feature-index]");
    const visual = featureLab.querySelector("[data-feature-visual]");
    if (index) index.textContent = option.dataset.featureIndex || "";
    if (visual) visual.textContent = option.dataset.featureVisual || "";
    syncFeatureLabLanguage();
    if (shouldAnimate) replayFeatureLab();
  }

  function setToggleState(paused) {
    if (!toggle) return;
    toggle.setAttribute("aria-pressed", String(paused));
    const label = toggle.querySelector("span");
    if (label) {
      label.textContent = paused
        ? english
          ? "Resume motion"
          : "继续旋转"
        : english
          ? "Pause motion"
          : "暂停旋转";
    }
  }

  function startOrbit() {
    if (!gallery || !track || !cards.length || prefersReducedMotion.matches)
      return;
    if (orbitTimeline) orbitTimeline.kill();
    gsap.set(track, {
      rotationX: 0,
      transformOrigin: "50% 50%",
    });
    gsap.set(cards, { clearProps: "transform,opacity,visibility,zIndex" });

    // Slow slightly at every front-facing position. The ring never cuts or
    // stops, but each screenshot gets a readable moment while facing forward.
    orbitTimeline = gsap.timeline({ repeat: -1 });
    [72, 144, 216, 288, 360].forEach(function (rotationY) {
      orbitTimeline.to(track, {
        rotationY: rotationY,
        duration: 5,
        ease: "sine.inOut",
      });
    });

    gallery.addEventListener(
      "pointerenter",
      function () {
        orbitTimeline.timeScale(0.24);
      },
      { passive: true },
    );
    gallery.addEventListener(
      "pointerleave",
      function () {
        orbitTimeline.timeScale(1);
      },
      { passive: true },
    );
    setToggleState(false);
  }

  gsap.matchMedia().add("(prefers-reduced-motion: no-preference)", startOrbit);

  if (toggle) {
    toggle.addEventListener("click", function () {
      if (!orbitTimeline) return;
      const paused = !orbitTimeline.paused();
      orbitTimeline.paused(paused);
      setToggleState(paused);
    });
  }

  featureOptions.forEach(function (option) {
    option.addEventListener("click", function () {
      selectFeature(option, true);
    });
    option.addEventListener("keydown", function (event) {
      if (event.key === "Enter" || event.key === " ") {
        event.preventDefault();
        selectFeature(option, true);
      }
    });
  });
  selectFeature(
    featureOptions.find(function (option) {
      return option.classList.contains("is-active");
    }) || featureOptions[0],
    false,
  );
  if (featureReplay) {
    featureReplay.addEventListener("click", replayFeatureLab);
  }

  setupCurtainReveals(false);
  // Horizontal pinning makes one section take many wheel gestures. The public
  // site now has four full-screen chapters, so that interaction is retired.
  try {
    setupChapterCurtains();
  } catch (error) {
    console.error("[serein] chapter curtain animation unavailable", error);
  }

  gsap.from(".hero-copy > *:not(h1)", {
    y: 22,
    autoAlpha: 0,
    duration: 0.7,
    stagger: 0.09,
    ease: "power3.out",
    immediateRender: false,
  });
  gsap.from(".orbit-card", {
    autoAlpha: 0,
    scale: 0.88,
    duration: 0.9,
    stagger: { each: 0.08, from: "center" },
    ease: "back.out(1.5)",
    immediateRender: false,
  });

  if (window.ScrollTrigger) {
    window.addEventListener(
      "load",
      function () {
        ScrollTrigger.refresh();
      },
      { once: true },
    );
  }
})();
