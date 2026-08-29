// auto-discover-tiktok-live.js
// 用途: 注入抖音进程后, 自动枚举可疑类 + 实时 hook 进入直播间的 view 树
// 用法:
//   1) 真机已装 frida (pip install frida-tools)
//   2) 启动抖音 (要让它跑起来)
//   3) 终端跑:  frida -U --codesign 抖音 -l auto-discover-tiktok-live.js
//      或:        frida -U -f com.ss.iphone.ugc.aweme.DYVideoFeed -l auto-discover-tiktok-live.js --no-pause
//   4) 进入任意正在发福袋的直播间
//   5) 终端会实时打印可疑 VC + 视图树
//   6) Ctrl-D 退出
//
// 输出: 终端 stdout 全部保存, 关键词: [VC appeared] / [AWE] / [Live] / [Lottery] / [Bag] / [Packet]
//
// 提示: 抖音包名常是 com.ss.iphone.ugc.aweme.DYVideoFeed 或 com.ss.iphone.ugc.Aweme;
//       如果不对, 用 `frida-ps -Uai` 列出所有 App 找对的那个.

'use strict';

const KEYWORDS = [
    'Live', 'Lottery', 'Packet', 'Bag', 'Red', 'Envelope',
    'Treasure', 'Game', 'Interact', 'Prize', 'Draw', 'Comment',
    'Chat', 'Barrage', 'Message', 'Anchor', 'Room', 'Task', 'Box',
    'Open', 'Pop', 'Dialog', 'Modal', 'Sheet', 'Toast', 'Notice',
    'Aweme', 'AWE', 'Awe'
];

console.log('=== 阶段 1: 枚举可疑类 ===');
const matched = {};
for (const name in ObjC.classes) {
    if (KEYWORDS.some(k => name.indexOf(k) !== -1)) {
        const c = ObjC.classes[name];
        try {
            matched[name] = {
                methods: (c.$ownMethods || []).length,
                props:   (c.$ownProperties || []).length,
            };
        } catch (e) { matched[name] = '?'; }
    }
}
const sorted = Object.keys(matched).sort();
console.log('匹配类数: ' + sorted.length);
console.log('--- 列表 ---');
sorted.forEach(n => {
    const m = matched[n];
    if (typeof m === 'object') {
        console.log(`  ${n}  methods=${m.methods} props=${m.props}`);
    } else {
        console.log(`  ${n}`);
    }
});

console.log('\n=== 阶段 2: 实时 hook VC 出现 + dump 视图树 ===');
const VC = ObjC.classes.UIViewController;
const vda = VC['- viewDidAppear:'];
if (!vda) {
    console.log('!! 找不到 UIViewController.viewDidAppear:, Frida API 变了');
} else {
    Interceptor.attach(vda.implementation, {
        onEnter(args) {
            const self = new ObjC.Object(args[0]);
            const cls = self.$className;
            // 只打我们关心的 VC
            if (KEYWORDS.some(k => cls.indexOf(k) !== -1) ||
                cls.indexOf('ViewController') !== -1) {
                console.log(`\n[VC appeared] ${cls}  (${self.toString().substring(0, 200)})`);
                // 200ms 后 dump 视图树
                setTimeout(() => {
                    try {
                        const view = self.view();
                        if (view) {
                            const tree = view.recursiveDescription().toString();
                            // 截前 6000 字符避免刷屏
                            console.log('  >> VIEW TREE (first 6000 chars):');
                            console.log(tree.substring(0, 6000).split('\n').map(l => '    ' + l).join('\n'));
                        }
                    } catch (e) {
                        console.log('  >> dump failed:', e);
                    }
                }, 200);
            }
        }
    });
    console.log('Hooked UIViewController.viewDidAppear: (ok)');
}

console.log('\n=== 阶段 3: hook 关键方法签名 (即使未触发, 也能看类存在与否) ===');
const CANDIDATES = [
    'openRedPacket', 'clickRedPacket', 'openPacket', 'openLottery',
    'receiveRedPacket', 'grabRedPacket', 'openTreasure', 'drawPrize',
    'clickDraw', 'openBox', 'openTask', 'sendComment', 'postComment',
    'onLotteryAppear', 'onRedPacketAppear', 'onLiveAppear'
];
for (const selName of CANDIDATES) {
    for (const cname in ObjC.classes) {
        try {
            const c = ObjC.classes[cname];
            // 模糊匹配: 方法名带 selName
            const ms = c.$methods || [];
            for (const m of ms) {
                if (m.toLowerCase().indexOf(selName.toLowerCase()) !== -1) {
                    console.log(`  [CANDIDATE] ${cname} -> ${m}`);
                    break;
                }
            }
        } catch (e) {}
    }
}

console.log('\n=== 准备就绪 === 现在进入直播间, 你会看到 [VC appeared] 和视图树。');
console.log('保存所有输出, 给我, 我帮你筛哪些是福袋/参与/评论/中奖 toast。');
