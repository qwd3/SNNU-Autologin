// ==UserScript==
// @name         Bilibili No-PCDN (SNNU)
// @namespace    snnu.local.nopcdn
// @version      2.0.0
// @description  Measure the candidate Bilibili CDN nodes and use the FASTEST one, instead of blindly preferring a fixed host. Keeps DASH and original quality. / 给每个候选节点实测测速，按速度选最快的，而不是盲目选“第一个正规备份”。保留 DASH 原画质。
// @author       local
// @match        *://*.bilibili.com/*
// @run-at       document-start
// @grant        none
// ==/UserScript==

/*
 * 背景（都是实测数据，不是猜的）
 * ------------------------------------------------------------------
 * SNNU 校园网移动代拨出口下，B站 /x/player/playurl 每次返回的节点都不一样：
 * 主地址常是 PCDN，备份里混着正规 CDN；同一批流里速度能差几十倍。
 *
 *   xy115x231x41x12xy.mcdn.bilivideo.cn   4MB 用 12.8s；15MB 直接超时、0 字节
 *   cn-sxxa-cm-01-01.bilivideo.com        8MB 用 0.30s ≈ 147 Mbps
 *   cn-sdjn-cm-02-01.bilivideo.com        并发约 69.6 Mbps
 *
 * 而且节点每次请求都在换（实测拿到过西安 / 济南 / 石家庄），所以「有时卡有时不卡」。
 *
 * v1 的做法是「把 PCDN 换成第一个非 PCDN 备份」—— 但那个备份也不保证快，
 * 抽到差节点照样卡。v2 改成：
 *
 *   1. 收集该流的全部候选地址（baseUrl + backupUrl）
 *   2. 对候选主机发 64KB Range 请求实测速度
 *   3. 按实测速度排序，最快的提为 baseUrl，其余降为备份
 *   4. 结果写入 localStorage（6 小时有效），越用越准、且刷新页面不丢
 *
 * 同步 / 异步的取舍
 * ------------------------------------------------------------------
 *   fetch 路径：可以 await 测速，首次播放就能选对。只有遇到「没测过的主机」才等，
 *               最多等 1.2 秒；缓存热了以后零延迟。
 *   XHR  路径：XHR 的响应必须同步交还，没法等测速。所以只用缓存同步排序，
 *               同时把测速丢到后台，下一次请求就准了。
 *   控制台会打印实际走的是哪条路（fetch / xhr），据此可判断首次播放有没有被优化。
 */

(function () {
    'use strict';

    // ------------------------------------------------------------ 配置
    var CFG = {
        probeBytes: 65536,               // 单次测速拉取字节数
        probeTimeoutMs: 4000,            // 单主机测速超时
        fetchBudgetMs: 1200,             // fetch 路径最多等测速多久
        scoreTtlMs: 6 * 3600 * 1000,     // 速度缓存有效期
        reprobeAfterMs: 10 * 60 * 1000,  // 同一主机多久内不重复测
        maxProbesPerResponse: 6,         // 单次响应最多测几个主机
        maxConcurrentProbes: 4,          // 并发测速上限
        storageKey: '__nopcdn_scores_v2'
    };

    var PCDN_RE = /(mcdn\.bilivideo\.(?:cn|com)|mountaintoys\.cn|szbdyd\.com)/i;

    // ------------------------------------------------------------ 状态
    var scores = {};          // host -> { bps, ts, fail }
    var probing = new Map();  // host -> Promise
    var probeQueue = 0;
    var stats = { replaced: 0, calls: 0, fetchCalls: 0, xhrCalls: 0, probes: 0 };

    function log(msg) {
        try {
            console.log('%c[No-PCDN]%c ' + msg,
                'color:#fff;background:#fb7299;padding:1px 4px;border-radius:3px', 'color:#fb7299');
        } catch (e) { }
    }
    function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }

    // ------------------------------------------------------------ 速度缓存
    function loadScores() {
        try {
            var raw = window.localStorage.getItem(CFG.storageKey);
            if (raw) scores = JSON.parse(raw) || {};
        } catch (e) { scores = {}; }
    }
    function saveScores() {
        try { window.localStorage.setItem(CFG.storageKey, JSON.stringify(scores)); } catch (e) { }
    }
    function isFresh(s) { return !!s && (Date.now() - s.ts) < CFG.scoreTtlMs; }
    function isPcdn(u) { return PCDN_RE.test(u); }

    function hostOf(u) {
        try {
            var base = (typeof location !== 'undefined' && location.href) ? location.href : undefined;
            return new URL(u, base).host;
        } catch (e) { return ''; }
    }

    // ------------------------------------------------------------ 测速
    function probeHost(host, url) {
        if (!host || !url) return Promise.resolve(null);
        if (probing.has(host)) return probing.get(host);

        var p = new Promise(function (resolve) {
            var done = false, ctrl = null;
            if (typeof AbortController !== 'undefined') { try { ctrl = new AbortController(); } catch (e) { } }
            var timer = setTimeout(function () { if (ctrl) { try { ctrl.abort(); } catch (e) { } } }, CFG.probeTimeoutMs);
            var now = function () { return (typeof performance !== 'undefined' && performance.now) ? performance.now() : Date.now(); };
            var t0 = now();

            function finish(ok, bps) {
                if (done) return;
                done = true;
                clearTimeout(timer);
                var prev = scores[host];
                if (ok && bps > 0) {
                    // 与历史值指数加权，避免一次抖动就误判
                    var merged = (prev && !prev.fail && prev.bps)
                        ? Math.round(prev.bps * 0.4 + bps * 0.6)
                        : Math.round(bps);
                    scores[host] = { bps: merged, ts: Date.now(), fail: false };
                } else {
                    scores[host] = { bps: 0, ts: Date.now(), fail: true };
                }
                saveScores();
                probing.delete(host);
                probeQueue = Math.max(0, probeQueue - 1);
                resolve(scores[host]);
            }

            var opts = {
                method: 'GET',
                headers: { 'Range': 'bytes=0-' + (CFG.probeBytes - 1) },
                credentials: 'omit',
                cache: 'no-store',
                mode: 'cors'
            };
            if (ctrl) opts.signal = ctrl.signal;

            try {
                fetch(url, opts).then(function (res) {
                    if (!res || (!res.ok && res.status !== 206)) { finish(false, 0); return null; }
                    return res.arrayBuffer().then(function (buf) {
                        var dt = (now() - t0) / 1000;
                        if (buf && buf.byteLength > 0 && dt > 0) finish(true, buf.byteLength / dt);
                        else finish(false, 0);
                    });
                }).catch(function () { finish(false, 0); });
            } catch (e) { finish(false, 0); }
        });

        probeQueue++;
        stats.probes++;
        probing.set(host, p);
        return p;
    }

    // 后台补测，不阻塞响应
    function scheduleProbes(cands) {
        var seen = {}, n = 0;
        for (var i = 0; i < cands.length && n < CFG.maxProbesPerResponse; i++) {
            var h = hostOf(cands[i]);
            if (!h || seen[h]) continue;
            seen[h] = 1;
            var s = scores[h];
            if (isFresh(s) && (Date.now() - s.ts) < CFG.reprobeAfterMs) continue;
            if (probing.has(h)) continue;
            if (probeQueue >= CFG.maxConcurrentProbes) continue;
            n++;
            probeHost(h, cands[i]);
        }
    }

    // ------------------------------------------------------------ 排序
    // 顺序： 实测快（降序） -> 没测过（非 PCDN 优先） -> 实测失败/为0
    function rankCandidates(cands) {
        var good = [], unknown = [], bad = [], seen = {};
        for (var i = 0; i < cands.length; i++) {
            var u = cands[i];
            if (!u || seen[u]) continue;
            seen[u] = 1;
            var s = scores[hostOf(u)];
            if (isFresh(s)) {
                if (s.fail || !s.bps) bad.push(u);
                else good.push({ u: u, bps: s.bps });
            } else {
                unknown.push(u);
            }
        }
        good.sort(function (a, b) { return b.bps - a.bps; });
        unknown.sort(function (a, b) { return (isPcdn(a) ? 1 : 0) - (isPcdn(b) ? 1 : 0); });
        var out = [];
        for (var g = 0; g < good.length; g++) out.push(good[g].u);
        return out.concat(unknown, bad);
    }

    // ------------------------------------------------------------ 流的收集与改写
    function collectStreams(node, out, depth) {
        out = out || []; depth = depth || 0;
        if (!node || typeof node !== 'object' || depth > 12) return out;
        if (Array.isArray(node)) {
            for (var i = 0; i < node.length; i++) collectStreams(node[i], out, depth + 1);
            return out;
        }
        if (typeof node.baseUrl === 'string' || typeof node.base_url === 'string') out.push(node);
        for (var k in node) {
            if (Object.prototype.hasOwnProperty.call(node, k)) collectStreams(node[k], out, depth + 1);
        }
        return out;
    }

    function candidatesOf(o) {
        var baseKey = (typeof o.baseUrl === 'string') ? 'baseUrl'
            : ((typeof o.base_url === 'string') ? 'base_url' : null);
        if (!baseKey) return null;
        var bkKey = Array.isArray(o.backupUrl) ? 'backupUrl'
            : (Array.isArray(o.backup_url) ? 'backup_url' : null);
        var cands = [o[baseKey]];
        if (bkKey) cands = cands.concat(o[bkKey] || []);
        return { baseKey: baseKey, bkKey: bkKey, cands: cands.filter(Boolean) };
    }

    function fixStream(o) {
        var info = candidatesOf(o);
        if (!info || info.cands.length < 2) return 0;
        var ordered = rankCandidates(info.cands);
        if (!ordered.length) return 0;
        var best = ordered[0], changed = 0;
        if (best !== o[info.baseKey]) { o[info.baseKey] = best; changed = 1; }
        if (info.bkKey) o[info.bkKey] = ordered.slice(1);
        return changed;
    }

    function applyRewrite(jsonText) {
        if (!jsonText || jsonText.charAt(0) !== '{') return null;
        var json;
        try { json = JSON.parse(jsonText); } catch (e) { return null; }
        var streams = collectStreams(json);
        if (!streams.length) return null;

        var replaced = 0, allCands = [];
        for (var i = 0; i < streams.length; i++) {
            var info = candidatesOf(streams[i]);
            if (info) allCands = allCands.concat(info.cands);
            replaced += fixStream(streams[i]);
        }
        stats.replaced = replaced;
        return { text: JSON.stringify(json), replaced: replaced, cands: allCands, streams: streams };
    }

    function describeWinners(streams) {
        var seen = {}, list = [];
        for (var i = 0; i < streams.length; i++) {
            var h = hostOf(streams[i].baseUrl || streams[i].base_url);
            if (h && !seen[h]) { seen[h] = 1; list.push(h); }
        }
        return list.join(' , ');
    }

    // ------------------------------------------------------------ 拦截 fetch
    if (window.fetch) {
        var origFetch = window.fetch;
        window.fetch = function (input, init) {
            var url = (typeof input === 'string') ? input : ((input && input.url) || '');
            var promise = origFetch.apply(this, arguments);
            if (!isPlayUrl(url)) return promise;

            return promise.then(function (res) {
                return res.clone().text().then(function (text) {
                    var first = applyRewrite(text);
                    if (!first) return res;

                    // 找出还没测过的主机
                    var unknown = [], seen = {};
                    for (var i = 0; i < first.cands.length; i++) {
                        var h = hostOf(first.cands[i]);
                        if (!h || seen[h]) continue;
                        seen[h] = 1;
                        if (!isFresh(scores[h])) unknown.push(first.cands[i]);
                    }

                    function deliver(finalText, note) {
                        stats.calls++; stats.fetchCalls++;
                        var st = collectStreams(JSON.parse(finalText));
                        stats.replaced = first.replaced;
                        log('fetch 路径：替换 ' + first.replaced + ' 个主地址' +
                            (note ? '（' + note + '）' : '') + '，使用节点: ' + describeWinners(st));
                        var hd = new Headers(res.headers);
                        hd.delete('content-encoding');
                        hd.delete('content-length');
                        hd.set('content-type', 'application/json; charset=utf-8');
                        return new Response(finalText, { status: res.status, statusText: res.statusText, headers: hd });
                    }

                    if (!unknown.length) return deliver(first.text);   // 缓存已热，零延迟

                    var probes = unknown.slice(0, CFG.maxProbesPerResponse).map(function (u) {
                        return probeHost(hostOf(u), u);
                    });
                    return Promise.race([Promise.all(probes), sleep(CFG.fetchBudgetMs)])
                        .then(function () {
                            var second = applyRewrite(text);   // 用刚测到的速度重排
                            return deliver(second ? second.text : first.text, '已测速 ' + probes.length + ' 个节点');
                        })
                        .catch(function () { return deliver(first.text, '测速失败，退回启发式'); });
                }).catch(function () { return res; });
            });
        };
    }

    // ------------------------------------------------------------ 拦截 XHR
    var XHR = XMLHttpRequest.prototype;
    var origOpen = XHR.open, origSend = XHR.send;

    XHR.open = function (method, url) {
        try { this.__nopcdn_play = isPlayUrl(url); } catch (e) { }
        return origOpen.apply(this, arguments);
    };

    XHR.send = function () {
        var self = this;
        if (self.__nopcdn_play) {
            self.addEventListener('readystatechange', function () {
                if (self.readyState !== 4) return;
                try {
                    var type = self.responseType;
                    if (type === '' || type === 'text') {
                        var r = applyRewrite(self.responseText);
                        if (r) {
                            stats.calls++; stats.xhrCalls++;
                            scheduleProbes(r.cands);   // XHR 等不了，测速丢后台，下次生效
                            log('xhr 路径：替换 ' + r.replaced + ' 个主地址（XHR 无法等待测速，本次按缓存排序，已后台补测）' +
                                '，使用节点: ' + describeWinners(r.streams));
                            defineOn(self, 'responseText', r.text);
                            defineOn(self, 'response', r.text);
                        }
                    } else if (type === 'json') {
                        var obj = self.response;
                        if (obj && typeof obj === 'object') {
                            var streams = collectStreams(obj);
                            if (streams.length) {
                                var replaced = 0, cands = [];
                                for (var i = 0; i < streams.length; i++) {
                                    var info = candidatesOf(streams[i]);
                                    if (info) cands = cands.concat(info.cands);
                                    replaced += fixStream(streams[i]);
                                }
                                if (replaced) {
                                    stats.calls++; stats.xhrCalls++;
                                    scheduleProbes(cands);
                                    log('xhr 路径(json)：替换 ' + replaced + ' 个主地址，使用节点: ' + describeWinners(streams));
                                    defineOn(self, 'response', obj);
                                }
                            }
                        }
                    }
                } catch (e) { }
            });
        }
        return origSend.apply(this, arguments);
    };

    function defineOn(target, prop, value) {
        try { Object.defineProperty(target, prop, { get: function () { return value; }, configurable: true }); }
        catch (e) { }
    }

    function isPlayUrl(u) {
        if (typeof u !== 'string') return false;
        return /\/x\/player\/(?:wbi\/)?playurl/.test(u) ||
               /\/pgc\/player\/web\/playurl/.test(u) ||
               /\/intl\/gweb\/x\/player\/playurl/.test(u);
    }

    // ------------------------------------------------------------ 自检接口
    window.__noPcdnStats = function () {
        return {
            totalReplaced: stats.replaced,
            calls: stats.calls,
            fetchCalls: stats.fetchCalls,
            xhrCalls: stats.xhrCalls,
            probes: stats.probes,
            scores: scores
        };
    };
    window.__noPcdnReset = function () {
        scores = {}; saveScores();
        log('速度缓存已清空，下次播放会重新测速');
    };
    // 供离线测试使用
    window.__noPcdnInternals = {
        rankCandidates: rankCandidates,
        applyRewrite: applyRewrite,
        collectStreams: collectStreams,
        hostOf: hostOf,
        setScores: function (s) { scores = s; },
        getScores: function () { return scores; },
        CFG: CFG,
        PCDN_RE: PCDN_RE
    };

    loadScores();
    log('v2 已加载（按实测速度选节点）。自检 __noPcdnStats()  清缓存 __noPcdnReset()');
})();
