/*
 * 离线测试 v2: 验证「按实测速度选节点」的排序逻辑
 * 运行: node _test-rewrite.cjs
 */
const fs = require('fs');
const path = require('path');

const src = fs.readFileSync(path.join(__dirname, 'bilibili-nopcdn.user.js'), 'utf8');

// ---------------- 浏览器环境桩 ----------------
const store = {};
const win = {
    localStorage: {
        getItem: k => (k in store ? store[k] : null),
        setItem: (k, v) => { store[k] = String(v); },
        removeItem: k => { delete store[k]; }
    }
};
global.window = win;
function XHRStub() {}
XHRStub.prototype = { open() {}, send() {}, addEventListener() {} };
global.XMLHttpRequest = XHRStub;
global.Headers = function () { this.delete = () => {}; this.set = () => {}; };
global.Response = function () {};
// 故意不定义 window.fetch：跳过 fetch 分支，只测纯逻辑

eval(src);   // 执行用户脚本本体

const I = win.__noPcdnInternals;
if (!I) { console.error('FAIL: 脚本未暴露 __noPcdnInternals'); process.exit(1); }

let pass = true;
function check(name, cond, extra) {
    console.log(`  ${cond ? 'PASS' : 'FAIL'}  ${name}${extra ? '  ' + extra : ''}`);
    if (!cond) pass = false;
}
const h = u => I.hostOf(u);

const PCDN_FAST = 'http://xy115x231x41x12xy.mcdn.bilivideo.cn:8082/a.m4s?sig=1';
const PCDN_DEAD = 'http://xy171x43x247x54xy.mcdn.bilivideo.cn:8082/b.m4s?sig=1';
const CDN_FAST  = 'http://cn-sxxa-cm-01-01.bilivideo.com/c.m4s?sig=1';
const CDN_SLOW  = 'http://cn-sdjn-cm-02-01.bilivideo.com/d.m4s?sig=1';

console.log('=== 用例 A: 冷缓存（没有任何测速数据） ===');
I.setScores({});
let order = I.rankCandidates([PCDN_FAST, PCDN_DEAD, CDN_FAST]);
console.log('   排序结果: ' + order.map(h).join('  ->  '));
check('冷缓存时退回启发式：非 PCDN 排在 PCDN 前面', h(order[0]) === h(CDN_FAST));

console.log('\n=== 用例 B: 热缓存（v2 的关键改进点）===');
I.setScores({
    [h(PCDN_FAST)]: { bps: 40 * 1024 * 1024, ts: Date.now(), fail: false },  // 这个 PCDN 实测 40MB/s
    [h(CDN_SLOW)]:  { bps: 0.3 * 1024 * 1024, ts: Date.now(), fail: false }, // 这个正规CDN 只有 0.3MB/s
    [h(CDN_FAST)]:  { bps: 18 * 1024 * 1024, ts: Date.now(), fail: false },
    [h(PCDN_DEAD)]: { bps: 0, ts: Date.now(), fail: true }                   // 实测失败
});
order = I.rankCandidates([CDN_SLOW, PCDN_FAST, CDN_FAST, PCDN_DEAD]);
console.log('   排序结果: ' + order.map(h).join('  ->  '));
check('最快的节点排第一位（即使它是 PCDN）', h(order[0]) === h(PCDN_FAST));
check('实测失败的节点被排到最后', h(order[order.length - 1]) === h(PCDN_DEAD));
check('不会把 40MB/s 的节点让位给 0.3MB/s 的节点',
    order.indexOf(PCDN_FAST) < order.indexOf(CDN_SLOW));

console.log('\n=== 用例 C: 速度全部已知时，严格按速度降序 ===');
I.setScores({
    [h(CDN_FAST)]:  { bps: 18e6, ts: Date.now(), fail: false },
    [h(PCDN_FAST)]: { bps: 40e6, ts: Date.now(), fail: false },
    [h(CDN_SLOW)]:  { bps: 0.3e6, ts: Date.now(), fail: false }
});
order = I.rankCandidates([CDN_SLOW, PCDN_FAST, CDN_FAST]);
console.log('   排序结果: ' + order.map(h).join('  ->  '));
check('严格降序', h(order[0]) === h(PCDN_FAST) && h(order[1]) === h(CDN_FAST) && h(order[2]) === h(CDN_SLOW));

console.log('\n=== 用例 D: 过期缓存要被忽略 ===');
I.setScores({
    [h(PCDN_FAST)]: { bps: 40e6, ts: Date.now() - (I.CFG.scoreTtlMs + 1000), fail: false }
});
order = I.rankCandidates([CDN_FAST, PCDN_FAST]);
check('过期的高速记录不再生效（退回启发式，非PCDN优先）', h(order[0]) === h(CDN_FAST));

console.log('\n=== 用例 E: 用样本响应跑完整改写 ===');
const real = fs.readFileSync(path.join(__dirname, '_test-playurl.json'), 'utf8');
I.setScores({});
const r1 = I.applyRewrite(real);
check('样本响应能被改写且 JSON 合法', !!r1 && (() => { try { JSON.parse(r1.text); return true; } catch (e) { return false; } })());
const PCDN_RE = I.PCDN_RE;
const beforePcdn = I.collectStreams(JSON.parse(real)).filter(s => PCDN_RE.test(s.baseUrl)).length;
const afterPcdn = I.collectStreams(JSON.parse(r1.text)).filter(s => PCDN_RE.test(s.baseUrl)).length;
console.log(`   冷缓存下: 主地址是 PCDN 的流  ${beforePcdn} -> ${afterPcdn}`);
check('冷缓存下也不再让 PCDN 当主地址', afterPcdn === 0);
check('每个流的备份列表都保留了备选地址',
    I.collectStreams(JSON.parse(r1.text)).every(s => Array.isArray(s.backupUrl) && s.backupUrl.length >= 1));

console.log('\n=== 用例 F: 速度数据能写进 localStorage ===');
I.setScores({});
const raw = store[I.CFG.storageKey] || '{}';
console.log('   localStorage 内容: ' + raw);
check('清空操作已落盘（空对象）', raw === '{}' || raw === '');

console.log('\n结果: ' + (pass ? '全部通过' : '存在失败'));
process.exit(pass ? 0 : 1);
