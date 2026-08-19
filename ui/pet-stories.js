(function () {
  "use strict";

  const stories = Array.from(document.querySelectorAll("[data-pet-story]"));
  if (!stories.length) return;

  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
  const timelines = new Map();
  let chapterTransitioning = false;

  function find(story, selector) {
    return story.querySelector(selector);
  }

  function findAll(story, selector) {
    return Array.from(story.querySelectorAll(selector));
  }

  function makeHelloStory(story) {
    const pair = find(story, ".pet-scene-sofa");
    const ground = find(story, ".pet-ground");
    const phone = find(story, ".pet-phone");
    const notice = find(story, ".pet-notice");
    const sparks = findAll(story, ".pet-spark");
    const label = find(story, ".pet-story-label");
    const timeline = gsap.timeline({
      paused: true,
      repeat: -1,
      defaults: { ease: "power3.inOut" },
    });

    timeline
      .set([pair, phone, notice, sparks, label, ground], {
        clearProps: "transform,opacity,visibility",
      })
      .set(pair, { xPercent: -50, y: 18, scale: 0.94, autoAlpha: 0 })
      .set([phone, notice, sparks], { autoAlpha: 0 })
      .set(phone, { y: 26, scale: 0.72, rotation: -7 })
      .set(notice, { x: -8, y: 10, scale: 0.86 })
      .set(label, { y: -8, autoAlpha: 0 })
      .set(ground, { scaleX: 0.55, autoAlpha: 0 })
      .to(ground, { scaleX: 1, autoAlpha: 1, duration: 0.7 }, 0)
      .to(pair, { y: 0, scale: 1, autoAlpha: 1, duration: 0.95 }, 0.08)
      .to(label, { y: 0, autoAlpha: 1, duration: 0.5 }, 0.28)
      .to(phone, { y: 0, scale: 1, rotation: 0, autoAlpha: 1, duration: 0.72, ease: "back.out(1.6)" }, 1.55)
      .to(notice, { x: 0, y: 0, scale: 1, autoAlpha: 1, duration: 0.52, ease: "back.out(1.5)" }, 2.15)
      .to(notice, { y: -5, duration: 0.36, repeat: 3, yoyo: true, ease: "sine.inOut" }, 2.75)
      .to(pair, { y: -3, scale: 1.008, duration: 1.15, repeat: 5, yoyo: true, ease: "sine.inOut" }, 2.8)
      .fromTo(sparks, { scale: 0.2, autoAlpha: 0 }, { scale: 1, autoAlpha: 1, duration: 0.35, stagger: 0.1, ease: "back.out(2)" }, 4.15)
      .to(sparks, { scale: 1.6, autoAlpha: 0, duration: 0.45, stagger: 0.08 }, 4.85)
      .to(phone, { rotation: 5, duration: 0.34, repeat: 3, yoyo: true, ease: "sine.inOut" }, 6.35)
      .to(notice, { y: 8, autoAlpha: 0, duration: 0.45 }, 9.15)
      .to(phone, { y: 22, scale: 0.78, autoAlpha: 0, duration: 0.55 }, 9.45)
      .to([pair, label, ground], { autoAlpha: 0, duration: 0.65, stagger: 0.05 }, 11.2)
      .to({}, { duration: 0.12 });
    return timeline;
  }

  function makeApprovalStory(story) {
    const pair = find(story, ".pet-scene-office");
    const ground = find(story, ".pet-ground");
    const card = find(story, ".pet-approval-card");
    const pending = find(story, ".pet-approval-pending");
    const done = find(story, ".pet-approval-done");
    const relay = find(story, ".pet-relay");
    const relayPulse = find(story, ".pet-relay i");
    const label = find(story, ".pet-story-label");
    const timeline = gsap.timeline({ paused: true, repeat: -1, defaults: { ease: "power3.inOut" } });

    timeline
      .set([pair, ground, card, relay, label], { clearProps: "transform,opacity,visibility" })
      .set(pair, { xPercent: -50, y: 18, scale: 0.95, autoAlpha: 0 })
      .set(card, { y: 28, scale: 0.78, autoAlpha: 0 })
      .set(relay, { autoAlpha: 0 })
      .set(relayPulse, { xPercent: -120, autoAlpha: 0 })
      .set(pending, { autoAlpha: 1 })
      .set(done, { autoAlpha: 0 })
      .set(label, { y: -8, autoAlpha: 0 })
      .set(ground, { scaleX: 0.5, autoAlpha: 0 })
      .to(ground, { scaleX: 1, autoAlpha: 1, duration: 0.7 }, 0)
      .to(pair, { y: 0, scale: 1, autoAlpha: 1, duration: 0.95 }, 0.08)
      .to(label, { y: 0, autoAlpha: 1, duration: 0.5 }, 0.25)
      .to(card, { y: 0, scale: 1, autoAlpha: 1, duration: 0.7, ease: "back.out(1.6)" }, 1.55)
      .to(relay, { autoAlpha: 1, duration: 0.35 }, 2.2)
      .to(relayPulse, { xPercent: 420, autoAlpha: 1, duration: 1.05, ease: "power1.inOut" }, 2.35)
      .to(pair, { y: -2, scale: 1.006, duration: 1.35, repeat: 4, yoyo: true, ease: "sine.inOut" }, 2.75)
      .to(card, { scale: 1.06, duration: 0.28, repeat: 1, yoyo: true, ease: "sine.inOut" }, 3.75)
      .to(pending, { y: -6, autoAlpha: 0, duration: 0.35 }, 4.35)
      .fromTo(done, { y: 7, autoAlpha: 0 }, { y: 0, autoAlpha: 1, duration: 0.42 }, 4.48)
      .set(relayPulse, { xPercent: -120 }, 5.05)
      .to(relayPulse, { xPercent: 420, duration: 1.05, ease: "power1.inOut" }, 5.1)
      .to(card, { y: -4, duration: 0.5, repeat: 1, yoyo: true, ease: "sine.inOut" }, 8.2)
      .to([card, relay], { y: 22, autoAlpha: 0, duration: 0.55, stagger: 0.08 }, 11.45)
      .to([pair, label, ground], { autoAlpha: 0, duration: 0.65, stagger: 0.05 }, 12.65)
      .to({}, { duration: 0.62 });
    return timeline;
  }

  function makeAgentStory(story) {
    const pair = find(story, ".pet-scene-floor");
    const ground = find(story, ".pet-ground");
    const terminal = find(story, ".pet-agent-status");
    const lines = findAll(story, ".pet-agent-status i");
    const check = find(story, ".pet-agent-status b");
    const signals = findAll(story, ".pet-agent-signal i");
    const label = find(story, ".pet-story-label");
    const timeline = gsap.timeline({ paused: true, repeat: -1, defaults: { ease: "power3.inOut" } });

    timeline
      .set([pair, ground, terminal, label, signals, lines, check], { clearProps: "transform,opacity,visibility" })
      .set(pair, { xPercent: -50, y: 16, scale: 0.95, autoAlpha: 0 })
      .set(terminal, { y: 30, scale: 0.76, autoAlpha: 0 })
      .set(lines, { scaleX: 0, autoAlpha: 0 })
      .set(check, { scale: 0, autoAlpha: 0 })
      .set(signals, { y: 8, scale: 0.3, autoAlpha: 0 })
      .set(label, { y: -8, autoAlpha: 0 })
      .set(ground, { scaleX: 0.52, autoAlpha: 0 })
      .to(ground, { scaleX: 1, autoAlpha: 1, duration: 0.65 }, 0)
      .to(pair, { y: 0, scale: 1, autoAlpha: 1, duration: 0.92 }, 0.08)
      .to(label, { y: 0, autoAlpha: 1, duration: 0.45 }, 0.25)
      .to(terminal, { y: 0, scale: 1, autoAlpha: 1, duration: 0.68, ease: "back.out(1.55)" }, 1.35)
      .to(lines, { scaleX: 1, autoAlpha: 1, duration: 0.45, stagger: 0.22, ease: "power2.out" }, 2.1)
      .to(pair, { y: -3, scale: 1.008, duration: 1.18, repeat: 4, yoyo: true, ease: "sine.inOut" }, 3.05)
      .to(signals, { y: 0, scale: 1, autoAlpha: 1, duration: 0.34, stagger: 0.12, ease: "back.out(2)" }, 4.05)
      .to(signals, { y: -9, autoAlpha: 0, duration: 0.4, stagger: 0.1 }, 4.72)
      .to(check, { scale: 1, autoAlpha: 1, duration: 0.45, ease: "back.out(2)" }, 5.15)
      .to(terminal, { y: -5, duration: 0.42, repeat: 1, yoyo: true, ease: "sine.inOut" }, 5.55)
      .to(lines, { autoAlpha: 0.42, duration: 0.45, repeat: 2, yoyo: true, stagger: 0.08 }, 8.35)
      .to(terminal, { y: 22, scale: 0.82, autoAlpha: 0, duration: 0.58 }, 10.55)
      .to([pair, label, ground], { autoAlpha: 0, duration: 0.65, stagger: 0.05 }, 11.6)
      .to({}, { duration: 0.42 });
    return timeline;
  }

  function makeCampStory(story) {
    const pair = find(story, ".pet-lounge-pair");
    const ground = find(story, ".pet-ground");
    const sea = find(story, ".pet-camp-sea");
    const tent = find(story, ".pet-camp-tent");
    const sun = find(story, ".pet-camp-sun");
    const sunRing = find(story, ".pet-camp-sun i");
    const leftCola = find(story, ".pet-cola-left");
    const rightCola = find(story, ".pet-cola-right");
    const leftPing = find(story, ".pet-phone-ping-left");
    const rightPing = find(story, ".pet-phone-ping-right");
    const breezes = findAll(story, ".pet-camp-breeze");
    const label = find(story, ".pet-story-label");
    const timeline = gsap.timeline({ paused: true, repeat: -1, defaults: { ease: "sine.inOut" } });

    timeline
      .set([pair, ground, sea, tent, sun, sunRing, leftCola, rightCola, leftPing, rightPing, breezes, label], { clearProps: "transform,opacity,visibility" })
      .set(pair, { xPercent: -50, y: 18, scale: 0.97, autoAlpha: 0 })
      .set(tent, { xPercent: -50, y: 16, scaleX: 0.84, scaleY: 0.72, autoAlpha: 0 })
      .set([leftCola, rightCola], { y: 18, autoAlpha: 0 })
      .set([leftPing, rightPing], { scale: 0.45, autoAlpha: 0 })
      .set([sea, sun, breezes], { autoAlpha: 0 })
      .set(sun, { scale: 0.72, y: 9 })
      .set(breezes, { x: -34 })
      .set(label, { y: -8, autoAlpha: 0 })
      .set(ground, { scaleX: 0.52, autoAlpha: 0 })
      .to(ground, { scaleX: 1, autoAlpha: 1, duration: 0.7 }, 0)
      .to(sea, { autoAlpha: 1, duration: 0.9 }, 0.1)
      .to(tent, { y: 0, scaleX: 1, scaleY: 1, autoAlpha: 1, duration: 0.92, ease: "back.out(1.25)" }, 0.22)
      .to(sun, { scale: 1, y: 0, autoAlpha: 1, duration: 1.05, ease: "power2.out" }, 0.15)
      .to(pair, { y: 0, scale: 1, autoAlpha: 1, duration: 1.02, ease: "power2.out" }, 0.52)
      .to(label, { y: 0, autoAlpha: 1, duration: 0.5 }, 0.25)
      .to([leftCola, rightCola], { y: 0, autoAlpha: 1, duration: 0.5, stagger: 0.12, ease: "back.out(1.6)" }, 1.55)
      .to(breezes, { x: 0, autoAlpha: 0.78, duration: 1.1, stagger: 0.22 }, 2.05)
      .to(sunRing, { rotation: 24, duration: 11.2, ease: "none" }, 2.1)
      .to(sea, { scaleX: 1.025, duration: 1.6, repeat: 6, yoyo: true }, 2.15)
      .to(tent, { scaleY: 1.012, duration: 2.05, repeat: 4, yoyo: true }, 2.3)
      .to(pair, { y: -2, scale: 1.006, duration: 1.75, repeat: 5, yoyo: true }, 2.35)
      .to(leftPing, { scale: 1.05, autoAlpha: 0.92, duration: 0.38, ease: "back.out(1.8)" }, 3.25)
      .to(leftPing, { scale: 1.7, autoAlpha: 0, duration: 0.72 }, 3.68)
      .to(leftCola, { y: -1, rotation: -2, scaleY: 1.015, duration: 0.82, repeat: 1, yoyo: true }, 4.05)
      .to(rightPing, { scale: 1.05, autoAlpha: 0.92, duration: 0.38, ease: "back.out(1.8)" }, 5.55)
      .to(rightPing, { scale: 1.7, autoAlpha: 0, duration: 0.72 }, 5.98)
      .to(pair, { xPercent: -50.35, duration: 0.82, repeat: 1, yoyo: true }, 7.15)
      .to([leftPing, rightPing], { scale: 1.02, autoAlpha: 0.82, duration: 0.34, stagger: 0.22, ease: "back.out(1.6)" }, 8.35)
      .to([leftPing, rightPing], { scale: 1.62, autoAlpha: 0, duration: 0.66, stagger: 0.22 }, 8.79)
      .to(rightCola, { y: -1, rotation: 2, scaleY: 1.015, duration: 0.82, repeat: 1, yoyo: true }, 8.42)
      .to(breezes, { x: 42, autoAlpha: 0, duration: 1.2, stagger: 0.18 }, 10.55)
      .to(pair, { y: 1, duration: 0.85 }, 11.25)
      .to([leftCola, rightCola, sun, sea, tent], { y: 18, autoAlpha: 0, duration: 0.65, stagger: 0.04 }, 13.2)
      .to([pair, label, ground], { autoAlpha: 0, duration: 0.68, stagger: 0.04 }, 13.85)
      .to({}, { duration: 0.36 });
    return timeline;
  }

  function makeTimeline(story) {
    if (story.dataset.petStory === "approval") return makeApprovalStory(story);
    if (story.dataset.petStory === "agent") return makeAgentStory(story);
    if (story.dataset.petStory === "camp") return makeCampStory(story);
    return makeHelloStory(story);
  }

  function setStatic(story) {
    story.classList.add("is-static");
    story.classList.remove("is-playing");
  }

  function activeChapterStory() {
    let closest = null;
    let distance = Infinity;
    stories.forEach(function (story) {
      const chapter = story.closest(".chapter") || story.parentElement;
      const rect = chapter.getBoundingClientRect();
      const currentDistance = Math.abs(rect.top);
      if (rect.bottom > 0 && rect.top < window.innerHeight && currentDistance < distance) {
        closest = story;
        distance = currentDistance;
      }
    });
    return closest;
  }

  function playStory(story, restart) {
    if (reduceMotion.matches || chapterTransitioning || document.hidden) return;
    timelines.forEach(function (timeline, item) {
      if (item === story) return;
      timeline.pause(0);
      item.classList.remove("is-playing");
    });
    const timeline = timelines.get(story);
    if (!timeline) return;
    story.classList.add("is-playing");
    if (restart || timeline.progress() === 0) timeline.restart();
    else timeline.resume();
  }

  function pauseStory(story, reset) {
    const timeline = timelines.get(story);
    if (!timeline) return;
    if (reset) timeline.pause(0);
    else timeline.pause();
    story.classList.remove("is-playing");
  }

  if (!window.gsap || reduceMotion.matches) {
    stories.forEach(setStatic);
    return;
  }

  stories.forEach(function (story) {
    timelines.set(story, makeTimeline(story));
  });

  if (window.ScrollTrigger) {
    gsap.registerPlugin(ScrollTrigger);
    stories.forEach(function (story, index) {
      const chapter = story.closest(".chapter") || story.parentElement;
      ScrollTrigger.create({
        id: "serein-pet-story-" + (index + 1),
        trigger: chapter,
        start: "top 56%",
        end: "bottom 44%",
        onEnter: function () { playStory(story, true); },
        onEnterBack: function () { playStory(story, true); },
        onLeave: function () { pauseStory(story, true); },
        onLeaveBack: function () { pauseStory(story, true); },
      });
    });
  } else if ("IntersectionObserver" in window) {
    const observer = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (entry.isIntersecting) playStory(entry.target, true);
        else pauseStory(entry.target, true);
      });
    }, { threshold: 0.58 });
    stories.forEach(function (story) { observer.observe(story); });
  }

  window.addEventListener("serein:chapter-transition", function (event) {
    chapterTransitioning = Boolean(event.detail && event.detail.active);
    if (chapterTransitioning) {
      timelines.forEach(function (timeline, story) {
        timeline.pause();
        story.classList.remove("is-playing");
      });
      return;
    }
    window.requestAnimationFrame(function () {
      const story = activeChapterStory();
      if (story) playStory(story, true);
    });
  });

  document.addEventListener("visibilitychange", function () {
    if (document.hidden) {
      timelines.forEach(function (timeline) { timeline.pause(); });
      return;
    }
    const story = activeChapterStory();
    if (story) playStory(story, false);
  });

  reduceMotion.addEventListener("change", function () {
    if (!reduceMotion.matches) return;
    timelines.forEach(function (timeline, story) {
      timeline.kill();
      setStatic(story);
    });
  });

  window.requestAnimationFrame(function () {
    const story = activeChapterStory();
    if (story) playStory(story, true);
    if (window.ScrollTrigger) ScrollTrigger.refresh();
  });
})();
