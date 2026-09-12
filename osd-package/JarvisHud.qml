import QtQuick
import Quickshell
import Quickshell.Io

Item {
    id: root

    property string daemonState: "idle"
    property var audio: null
    property var theme: null
    property var recipe: null
    property string assetRoot: ""

    property real peak: 0.0
    property real rms: 0.0
    property real vadLevel: 0.0
    property real smoothPeak: 0.0
    property real smoothRms: 0.0
    property real phase: 0.0
    property real lastTickMs: Date.now()
    property real appear: 1.0
    property string priorState: "idle"
    property var samples: []

    readonly property bool active: daemonState === "recording"
        || daemonState === "streaming"
        || daemonState === "transcribing"

    function _configValue(key, fallback) {
        return theme && theme.config && theme.config[key] !== undefined
            ? theme.config[key]
            : fallback;
    }

    function _color(role, fallback) {
        if (theme && theme.color)
            return theme.color(role, fallback);
        return fallback;
    }

    function _stateColor() {
        if (daemonState === "streaming")
            return _color("streaming", "#6EA8FF");
        if (daemonState === "transcribing")
            return _color("transcribing", "#FFC857");
        if (daemonState === "recording")
            return _color("recording", "#4CC9FF");
        return _color("idle", "rgba(140, 214, 235, 0.55)");
    }

    function _stateLabel() {
        if (daemonState === "streaming")
            return "STREAMING";
        if (daemonState === "transcribing")
            return "PROCESSING";
        if (daemonState === "recording")
            return vadLevel > 0.45 ? "LISTENING" : "STANDBY";
        return "IDLE";
    }

    function _clamp(v, lo, hi) {
        return Math.max(lo, Math.min(hi, v));
    }

    function _approach(current, target, stiffness, dt) {
        const amount = 1.0 - Math.exp(-Math.max(0.01, stiffness) * dt);
        return current + (target - current) * amount;
    }

    function _hudSize() {
        return Math.min(188, Math.max(132, Math.min(root.width, root.height) * 0.16));
    }

    function _hudX(size) {
        const position = String(_configValue("position", "bottom-center"));
        const margin = Math.max(0, Number(_configValue("margin_px", 24)));
        if (position.indexOf("left") >= 0)
            return margin;
        if (position.indexOf("right") >= 0)
            return Math.max(margin, root.width - size - margin);
        return Math.max(margin, (root.width - size) / 2);
    }

    function _hudY(size) {
        const position = String(_configValue("position", "bottom-center"));
        const margin = Math.max(0, Number(_configValue("margin_px", 24)));
        const labelRoom = Math.round(size * 0.30);
        if (position === "top-left" || position === "top-right" || position === "top-center")
            return margin;
        if (position.indexOf("bottom") >= 0) {
            const dockClearance = 88;
            return Math.max(margin, root.height - size - margin - labelRoom - dockClearance);
        }
        const topMargin = _clamp(Number(_configValue("top_margin", 0.78)), 0.0, 1.0);
        return Math.max(margin, Math.min(root.height - size - margin - labelRoom, root.height * topMargin));
    }

    function _sample(index, count) {
        const r = samples || [];
        if (r.length > 1) {
            const pos = index * (r.length - 1) / Math.max(1, count - 1);
            const lo = Math.floor(pos);
            const hi = Math.min(r.length - 1, lo + 1);
            return r[lo] * (1 - (pos - lo)) + r[hi] * (pos - lo);
        }
        return 0.012 + 0.01 * Math.sin(phase * 1.1 + index * 0.41);
    }

    function _withAlpha(color, alpha) {
        const str = String(color);
        if (str[0] === "#" && str.length === 7) {
            const r = parseInt(str.slice(1, 3), 16);
            const g = parseInt(str.slice(3, 5), 16);
            const b = parseInt(str.slice(5, 7), 16);
            return "rgba(" + r + ", " + g + ", " + b + ", " + alpha + ")";
        }
        if (str[0] === "#" && str.length === 9) {
            const r = parseInt(str.slice(3, 5), 16);
            const g = parseInt(str.slice(5, 7), 16);
            const b = parseInt(str.slice(7, 9), 16);
            return "rgba(" + r + ", " + g + ", " + b + ", " + alpha + ")";
        }
        const m = /^rgba?\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)/.exec(str);
        if (m)
            return "rgba(" + m[1] + ", " + m[2] + ", " + m[3] + ", " + alpha + ")";
        return color;
    }

    function _playIntro() {
        appear = 0;
        introAnim.restart();
    }

    FileView {
        path: {
            const xdg = Quickshell.env("XDG_RUNTIME_DIR");
            if (xdg && xdg.length > 0)
                return xdg + "/voxtype/state";
            return "/run/user/1000/voxtype/state";
        }
        watchChanges: true
        printErrors: false
        onLoaded: {
            const next = (text() || "idle").trim();
            if (next.length > 0 && next !== root.daemonState)
                root.daemonState = next;
        }
        onFileChanged: reload()
    }

    Connections {
        target: root.audio
        enabled: root.audio !== null

        function onFrameReceived(framePeak, frameRms, vad) {
            root.peak = root._clamp(framePeak, 0.0, 1.0);
            root.rms = root._clamp(frameRms, 0.0, 1.0);
            root.vadLevel = vad ? 1.0 : 0.0;
            const next = root.samples.slice();
            next.push(root.peak);
            while (next.length > 72)
                next.shift();
            root.samples = next;
        }

        function onDisconnected() {
            root.peak = 0.0;
            root.rms = 0.0;
            root.vadLevel = 0.0;
            root.samples = [];
        }
    }

    onDaemonStateChanged: {
        const wasActive = priorState === "recording"
            || priorState === "streaming"
            || priorState === "transcribing";
        priorState = daemonState;
        if (!root.active) {
            peak = 0.0;
            rms = 0.0;
            vadLevel = 0.0;
            samples = [];
        } else if (!wasActive) {
            _playIntro();
        }
        hud.requestPaint();
    }

    onVisibleChanged: {
        if (visible && root.active)
            _playIntro();
    }

    NumberAnimation {
        id: introAnim
        target: root
        property: "appear"
        from: 0
        to: 1
        duration: 420
        easing.type: Easing.OutCubic
    }

    Timer {
        interval: 16
        repeat: true
        running: root.visible && root.active
        triggeredOnStart: true
        onTriggered: {
            const now = Date.now();
            const dt = Math.min(0.05, Math.max(0.001, (now - root.lastTickMs) / 1000.0));
            root.lastTickMs = now;
            root.phase += dt;
            root.smoothPeak = root._approach(root.smoothPeak, root.peak, 16.0, dt);
            root.smoothRms = root._approach(root.smoothRms, root.rms, 11.0, dt);
            root.vadLevel = root._approach(root.vadLevel, root.audio && root.audio.vad ? 1.0 : 0.0, 10.0, dt);
            hud.requestPaint();
        }
    }

    Canvas {
        id: hud
        anchors.fill: parent
        antialiasing: true
        opacity: root.active ? 1 : 0
        Behavior on opacity {
            NumberAnimation { duration: 220; easing.type: Easing.OutCubic }
        }

        function _hexPath(ctx, cx, cy, radius, rotation) {
            ctx.beginPath();
            for (let i = 0; i < 6; i++) {
                const a = rotation + i * Math.PI / 3 - Math.PI / 2;
                const x = cx + Math.cos(a) * radius;
                const y = cy + Math.sin(a) * radius;
                if (i === 0)
                    ctx.moveTo(x, y);
                else
                    ctx.lineTo(x, y);
            }
            ctx.closePath();
        }

        function _softDisc(ctx, cx, cy, radius, color, alpha) {
            const g = ctx.createRadialGradient(cx, cy, radius * 0.08, cx, cy, radius);
            g.addColorStop(0.0, root._withAlpha(color, alpha));
            g.addColorStop(0.38, root._withAlpha(color, alpha * 0.28));
            g.addColorStop(1.0, "rgba(0, 0, 0, 0)");
            ctx.fillStyle = g;
            ctx.beginPath();
            ctx.arc(cx, cy, radius, 0, Math.PI * 2);
            ctx.fill();
        }

        function _arc(ctx, cx, cy, radius, width, color, alpha, a0, a1) {
            ctx.save();
            ctx.globalAlpha = alpha;
            ctx.strokeStyle = color;
            ctx.lineWidth = width;
            ctx.lineCap = "round";
            ctx.beginPath();
            ctx.arc(cx, cy, radius, a0, a1);
            ctx.stroke();
            ctx.restore();
        }

        function _ticks(ctx, cx, cy, radius, count, inner, color, alpha, spin) {
            ctx.save();
            ctx.strokeStyle = color;
            ctx.lineWidth = 1.15;
            for (let i = 0; i < count; i++) {
                const a = spin + i * Math.PI * 2 / count;
                const longTick = i % 8 === 0;
                ctx.globalAlpha = alpha * (longTick ? 1.0 : 0.45);
                const len = longTick ? inner * 1.7 : inner;
                ctx.beginPath();
                ctx.moveTo(cx + Math.cos(a) * (radius - len), cy + Math.sin(a) * (radius - len));
                ctx.lineTo(cx + Math.cos(a) * radius, cy + Math.sin(a) * radius);
                ctx.stroke();
            }
            ctx.restore();
        }

        function _voiceCrown(ctx, cx, cy, radius, color, secondary) {
            const count = 56;
            ctx.save();
            ctx.lineCap = "round";
            for (let i = 0; i < count; i++) {
                const t = i / count;
                const sample = root._sample(i, count);
                const shaped = root._clamp(sample * 5.2 + root.smoothRms * 1.4, 0.02, 1.0);
                const a = -Math.PI / 2 + t * Math.PI * 2;
                const len = 3 + shaped * 16;
                ctx.strokeStyle = i % 4 === 0 ? secondary : color;
                ctx.lineWidth = i % 4 === 0 ? 2.1 : 1.15;
                ctx.globalAlpha = 0.22 + shaped * 0.78;
                ctx.beginPath();
                ctx.moveTo(cx + Math.cos(a) * (radius - len * 0.35), cy + Math.sin(a) * (radius - len * 0.35));
                ctx.lineTo(cx + Math.cos(a) * (radius + len), cy + Math.sin(a) * (radius + len));
                ctx.stroke();
            }
            ctx.restore();
        }

        onPaint: {
            const ctx = getContext("2d");
            ctx.clearRect(0, 0, width, height);
            if (!root.active)
                return;

            const size = root._hudSize();
            const x = root._hudX(size);
            const y = root._hudY(size);
            const cx = x + size / 2;
            const cy = y + size / 2;
            const r = size / 2;
            const state = root._stateColor();
            const accent = root._color("accent", "#4CC9FF");
            const fg = root._color("foreground", "#E8FBFF");
            const muted = root._color("muted", "rgba(140, 214, 235, 0.70)");
            const core = root._color("core", "#D8F7FF");
            const glow = root._color("glow", "rgba(40, 180, 255, 0.42)");
            const grid = root._color("grid", "rgba(76, 201, 255, 0.28)");
            const energy = root._clamp(root.smoothPeak * 1.5 + root.smoothRms * 2.8 + root.vadLevel * 0.22, 0.0, 1.0);
            const spinSlow = root.phase * 0.28;
            const spinFast = -root.phase * (0.85 + energy * 0.55);
            const pop = 0.70 + Math.min(1.0, Math.max(0.0, root.appear)) * 0.30;

            ctx.save();
            ctx.translate(cx, cy);
            ctx.scale(pop, pop);
            ctx.translate(-cx, -cy);

            _softDisc(ctx, cx, cy, r * (1.18 + energy * 0.16), glow, 0.55 + energy * 0.35);
            _softDisc(ctx, cx, cy, r * 0.42, state, 0.22 + energy * 0.28);

            ctx.save();
            ctx.globalAlpha = 0.62;
            ctx.fillStyle = root._color("background", "rgba(2, 10, 22, 0.55)");
            ctx.beginPath();
            ctx.arc(cx, cy, r * 0.58, 0, Math.PI * 2);
            ctx.fill();
            ctx.restore();

            _ticks(ctx, cx, cy, r * 0.94, 72, 7, state, 0.55, spinSlow);
            _voiceCrown(ctx, cx, cy, r * 0.72, state, fg);

            _arc(ctx, cx, cy, r * 0.86, 1.4, grid, 0.55, 0, Math.PI * 2);
            _arc(ctx, cx, cy, r * (0.78 + energy * 0.03), 2.6, state, 0.78 + energy * 0.18, spinFast, spinFast + Math.PI * 1.45);
            _arc(ctx, cx, cy, r * 0.78, 1.6, fg, 0.28, spinFast + Math.PI, spinFast + Math.PI * 1.72);
            _arc(ctx, cx, cy, r * (0.50 + root.smoothRms * 0.05), 2.0, accent, 0.85, -Math.PI * 0.15, Math.PI * 1.45);

            ctx.save();
            ctx.strokeStyle = state;
            ctx.lineWidth = 1.6;
            ctx.globalAlpha = 0.72 + energy * 0.22;
            _hexPath(ctx, cx, cy, r * 0.34, spinSlow * 0.35);
            ctx.stroke();
            ctx.lineWidth = 1.1;
            ctx.globalAlpha = 0.40;
            ctx.strokeStyle = fg;
            _hexPath(ctx, cx, cy, r * 0.26, -spinSlow * 0.5 + Math.PI / 6);
            ctx.stroke();
            ctx.restore();

            ctx.save();
            const coreR = r * (0.13 + energy * 0.045);
            const coreGrad = ctx.createRadialGradient(cx, cy, 0, cx, cy, coreR);
            coreGrad.addColorStop(0.0, core);
            coreGrad.addColorStop(0.45, accent);
            coreGrad.addColorStop(1.0, root._withAlpha(state, 0.15));
            ctx.fillStyle = coreGrad;
            ctx.globalAlpha = 0.92;
            ctx.beginPath();
            ctx.arc(cx, cy, coreR, 0, Math.PI * 2);
            ctx.fill();
            ctx.restore();

            ctx.save();
            ctx.strokeStyle = state;
            ctx.lineWidth = 1.1;
            ctx.globalAlpha = 0.55 + energy * 0.25;
            const arm = r * 0.98;
            const gap = r * 0.62;
            ctx.beginPath();
            ctx.moveTo(cx - arm, cy);
            ctx.lineTo(cx - gap, cy);
            ctx.moveTo(cx + gap, cy);
            ctx.lineTo(cx + arm, cy);
            ctx.moveTo(cx, cy - arm);
            ctx.lineTo(cx, cy - gap);
            ctx.moveTo(cx, cy + gap);
            ctx.lineTo(cx, cy + arm);
            ctx.stroke();
            ctx.restore();

            ctx.save();
            ctx.textAlign = "center";
            ctx.textBaseline = "middle";
            ctx.font = "600 " + Math.max(11, Math.round(size * 0.09)) + "px JetBrains Mono, monospace";
            ctx.fillStyle = state;
            ctx.globalAlpha = 0.96;
            ctx.fillText(root._stateLabel(), cx, cy + r * 1.12);
            ctx.restore();
            ctx.restore();
        }
    }
}
