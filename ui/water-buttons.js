(function () {
  "use strict";

  const SELECTOR = [
    "a.button",
    "button.language-toggle",
    "a.header-github",
    "button.gallery-control",
    "button.playground-replay",
    "button.workflow-screen-action",
  ].join(",");
  const COLUMNS = 48;
  const SUBSTEPS = 4;
  const GRAVITY = 4200;
  const VISCOSITY = 3.1;
  const IDLE_WATER_LEVEL = 0.12;
  const HOVER_WATER_LEVEL = 0.86;
  const WATER_LEVEL_RESPONSE = 5.8;
  const STILL = 0.035;

  function roundedRect(context, width, height, radius) {
    const r = Math.min(radius, width / 2, height / 2);
    context.beginPath();
    context.moveTo(r, 0);
    context.arcTo(width, 0, width, height, r);
    context.arcTo(width, height, 0, height, r);
    context.arcTo(0, height, 0, 0, r);
    context.arcTo(0, 0, width, 0, r);
    context.closePath();
  }

  function createWaterButton(root) {
    if (root.dataset.waterButtonReady === "true") return;
    root.dataset.waterButtonReady = "true";
    root.classList.add("water-button");

    const content = document.createElement("span");
    content.className = "water-button-content";
    while (root.firstChild) content.appendChild(root.firstChild);

    const canvas = document.createElement("canvas");
    canvas.className = "water-button-canvas";
    canvas.setAttribute("aria-hidden", "true");
    root.append(canvas, content);

    const context = canvas.getContext("2d");
    if (!context) return;

    const height = new Float32Array(COLUMNS);
    const velocity = new Float32Array(COLUMNS + 1);
    const flux = new Float32Array(COLUMNS + 1);
    const pointer = { x: -9999, y: -9999, vx: 0, vy: 0 };
    let width = 0;
    let canvasHeight = 0;
    let columnWidth = 1;
    let rest = 0;
    let targetRest = 0;
    let hovering = false;
    let running = false;
    let raf = 0;
    let previous = 0;
    let quietFrames = 0;
    let chapterTransitionPaused =
      document.body.classList.contains("chapter-transitioning");

    function resize() {
      const rect = root.getBoundingClientRect();
      width = Math.max(2, rect.width);
      canvasHeight = Math.max(2, rect.height);
      const dpr = Math.min(2, window.devicePixelRatio || 1);
      canvas.width = Math.round(width * dpr);
      canvas.height = Math.round(canvasHeight * dpr);
      context.setTransform(dpr, 0, 0, dpr, 0, 0);
      columnWidth = width / COLUMNS;
      rest = canvasHeight * IDLE_WATER_LEVEL;
      targetRest = rest;
      height.fill(rest);
      velocity.fill(0);
      draw();
    }

    function wake() {
      if (chapterTransitionPaused) return;
      quietFrames = 0;
      if (running) return;
      running = true;
      previous = 0;
      raf = requestAnimationFrame(loop);
    }

    function drive(delta) {
      const reach = Math.max(22, width * 0.15);
      const first = Math.max(1, Math.floor((pointer.x - reach) / columnWidth));
      const last = Math.min(
        COLUMNS - 1,
        Math.ceil((pointer.x + reach) / columnWidth),
      );
      for (let index = first; index <= last; index += 1) {
        const dx = index * columnWidth - pointer.x;
        const influence = 1 - Math.abs(dx) / reach;
        if (influence <= 0) continue;
        if (pointer.y < canvasHeight - height[index] - reach) continue;
        const sweep = Math.max(-7, Math.min(7, pointer.vx));
        const dip = Math.max(-7, Math.min(7, pointer.vy));
        velocity[index] +=
          (sweep * 190 + Math.sign(dx || 1) * dip * 68) * influence * delta;
      }
    }

    function splash(x) {
      const reach = Math.max(20, width * 0.13);
      for (let index = 1; index < COLUMNS; index += 1) {
        const dx = index * columnWidth - x;
        const influence = 1 - Math.abs(dx) / reach;
        if (influence > 0) {
          velocity[index] += Math.sign(dx || 1) * 150 * influence;
        }
      }
      wake();
    }

    function step(delta) {
      const substep = delta / SUBSTEPS;
      for (let stepIndex = 0; stepIndex < SUBSTEPS; stepIndex += 1) {
        rest +=
          (targetRest - rest) *
          Math.min(1, WATER_LEVEL_RESPONSE * substep);
        if (hovering) drive(substep);

        for (let index = 1; index < COLUMNS; index += 1) {
          velocity[index] +=
            ((-GRAVITY * (height[index] - height[index - 1])) / columnWidth) *
            substep;
          velocity[index] -= velocity[index] * Math.min(1, VISCOSITY * substep);
        }
        velocity[0] = 0;
        velocity[COLUMNS] = 0;

        for (let index = 1; index < COLUMNS; index += 1) {
          flux[index] =
            (velocity[index] > 0 ? height[index - 1] : height[index]) *
            velocity[index];
        }
        flux[0] = 0;
        flux[COLUMNS] = 0;

        for (let index = 0; index < COLUMNS; index += 1) {
          height[index] -=
            ((flux[index + 1] - flux[index]) / columnWidth) * substep;
          height[index] +=
            (rest - height[index]) *
            Math.min(1, WATER_LEVEL_RESPONSE * substep);
          height[index] = Math.max(0, height[index]);
        }
      }

      let worst = 0;
      for (let index = 0; index < COLUMNS; index += 1) {
        worst = Math.max(worst, Math.abs(height[index] - rest));
      }
      return worst;
    }

    function draw() {
      context.clearRect(0, 0, width, canvasHeight);
      context.save();
      roundedRect(
        context,
        width,
        canvasHeight,
        root.classList.contains("gallery-control")
          ? canvasHeight / 2
          : Math.min(13, canvasHeight * 0.28),
      );
      context.clip();

      const surface = function (index) {
        return canvasHeight - height[index];
      };
      context.beginPath();
      context.moveTo(0, surface(0));
      for (let index = 0; index < COLUMNS; index += 1) {
        context.lineTo((index + 0.5) * columnWidth, surface(index));
      }
      context.lineTo(width, surface(COLUMNS - 1));
      context.lineTo(width, canvasHeight);
      context.lineTo(0, canvasHeight);
      context.closePath();

      context.fillStyle = "rgba(223, 114, 85, 0.84)";
      context.fill();

      context.beginPath();
      context.moveTo(0, surface(0));
      for (let index = 0; index < COLUMNS; index += 1) {
        context.lineTo((index + 0.5) * columnWidth, surface(index));
      }
      context.lineTo(width, surface(COLUMNS - 1));
      context.strokeStyle = "rgba(255, 242, 233, 0.94)";
      context.lineWidth = 1.2;
      context.stroke();
      context.restore();
    }

    function loop(now) {
      if (chapterTransitionPaused) {
        running = false;
        previous = 0;
        return;
      }
      const delta = previous
        ? Math.min((now - previous) / 1000, 1 / 30)
        : 1 / 60;
      previous = now;
      pointer.vx *= 0.82;
      pointer.vy *= 0.82;
      const worst = step(delta);
      draw();

      if (!hovering && worst < STILL) quietFrames += 1;
      else quietFrames = 0;

      if (quietFrames > 24) {
        height.fill(rest);
        velocity.fill(0);
        draw();
        running = false;
        return;
      }
      raf = requestAnimationFrame(loop);
    }

    window.addEventListener("serein:chapter-transition", function (event) {
      chapterTransitionPaused = Boolean(event.detail?.active);
      if (chapterTransitionPaused) {
        cancelAnimationFrame(raf);
        running = false;
        previous = 0;
      } else if (hovering) {
        wake();
      }
    });

    function localPoint(event) {
      const rect = root.getBoundingClientRect();
      return {
        x: event.clientX - rect.left,
        y: event.clientY - rect.top,
      };
    }

    root.addEventListener("pointerenter", function (event) {
      const point = localPoint(event);
      hovering = true;
      targetRest = canvasHeight * HOVER_WATER_LEVEL;
      pointer.x = point.x;
      pointer.y = point.y;
      pointer.vx = 0;
      pointer.vy = 0;
      splash(point.x);
      wake();
    });
    root.addEventListener("pointermove", function (event) {
      const point = localPoint(event);
      pointer.vx = point.x - pointer.x;
      pointer.vy = point.y - pointer.y;
      pointer.x = point.x;
      pointer.y = point.y;
      wake();
    });
    root.addEventListener("pointerleave", function () {
      hovering = false;
      targetRest = canvasHeight * IDLE_WATER_LEVEL;
      pointer.x = -9999;
      pointer.y = -9999;
      pointer.vx = 0;
      pointer.vy = 0;
      wake();
    });
    root.addEventListener("pointerdown", function (event) {
      splash(localPoint(event).x);
    });

    const observer = new ResizeObserver(resize);
    observer.observe(root);
    resize();
  }

  document.querySelectorAll(SELECTOR).forEach(createWaterButton);
})();
