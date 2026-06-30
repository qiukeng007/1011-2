import 'dart:io';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

void main() async {
  final pdf = pw.Document();
  final f = pw.Font.helvetica();
  final fb = pw.Font.helveticaBold();
  final blue = PdfColors.blue900;
  final grey = PdfColors.grey700;
  final green = PdfColors.green800;

  pw.Widget t(String s) => pw.Text(s, style: pw.TextStyle(font: f, fontSize: 11, lineSpacing: 1.5));
  pw.Widget h(String s) => pw.Text(s, style: pw.TextStyle(font: fb, fontSize: 17, color: blue));
  pw.Widget h2(String s) => pw.Text(s, style: pw.TextStyle(font: fb, fontSize: 14, color: blue));
  pw.Widget b(String s) => pw.Text(s, style: pw.TextStyle(font: fb, fontSize: 11));
  pw.Widget g(String s) => pw.Text(s, style: pw.TextStyle(font: fb, fontSize: 11, color: green));
  pw.Widget box(String s) => pw.Container(
        padding: const pw.EdgeInsets.all(10),
        margin: const pw.EdgeInsets.only(top: 6, bottom: 6),
        decoration: pw.BoxDecoration(
          border: pw.Border.all(color: PdfColors.grey400),
          borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
          color: PdfColors.grey50,
        ),
        child: pw.Text(s, style: pw.TextStyle(font: f, fontSize: 10, lineSpacing: 1.3)),
      );

  pw.Widget table(List<String> headers, List<List<dynamic>> rows) {
    return pw.TableHelper.fromTextArray(
      headers: headers,
      data: rows.map((r) => r.map((c) => c.toString()).toList()).toList(),
      headerStyle: pw.TextStyle(font: fb, fontSize: 10, color: PdfColors.white),
      cellStyle: pw.TextStyle(font: f, fontSize: 10),
      headerDecoration: pw.BoxDecoration(color: PdfColors.blue800),
      cellPadding: const pw.EdgeInsets.all(6),
      columnWidths: headers.length == 2
          ? {0: const pw.FixedColumnWidth(120), 1: const pw.FlexColumnWidth(1)}
          : null,
    );
  }

  pw.PageTheme page = pw.PageTheme(
      margin: const pw.EdgeInsets.fromLTRB(28, 40, 28, 28),
      pageFormat: PdfPageFormat.a4);

  // ===== 封面 =====
  pdf.addPage(pw.Page(
    pageTheme: pw.PageTheme(margin: const pw.EdgeInsets.all(50)),
    build: (c) => pw.Center(
      child: pw.Column(
          mainAxisAlignment: pw.MainAxisAlignment.center,
          children: [
            pw.Text('cash carry',
                style: pw.TextStyle(font: fb, fontSize: 44, color: PdfColors.blue900)),
            pw.SizedBox(height: 8),
            pw.Text('银豹多店库存查询',
                style: pw.TextStyle(font: f, fontSize: 22, color: PdfColors.grey600)),
            pw.SizedBox(height: 30),
            pw.Text('使用文档 v1.0.6',
                style: pw.TextStyle(font: f, fontSize: 14, color: PdfColors.grey500)),
            pw.Text('2026 年 5 月',
                style: pw.TextStyle(font: f, fontSize: 12, color: PdfColors.grey400)),
          ]),
    ),
  ));

  // ===== 一、概述 =====
  pdf.addPage(pw.MultiPage(pageTheme: page, build: (c) => [
        h('一、APP 概述'),
        pw.SizedBox(height: 10),
        t('cash carry（银豹查询）是 Android 平台的多门店库存管理工具，对接银豹 POSPal 后台，'
            '支持条码扫描查库存、拍照补货、顾客预定、订单管理。'),
        pw.SizedBox(height: 6),
        t('核心数据流：手机 APP → 本地 WebServer(http://192.168.1.138) → 银豹后台(https://beta28.pospal.cn)'),
        pw.SizedBox(height: 14),
        table(['功能模块', '说明'], [
          ['多店库存查询', '扫码或手动输入条码，同时查询所有已配置门店的库存、进价、售价'],
          ['日常补货', '选择供货商 → 拍照上传 → 提交补货单到 WebServer'],
          ['顾客预定', '登记顾客电话 + 规格说明 + 照片 → 提交预定单'],
          ['订单查询', '按供货商筛选 / 搜索 / 排序 / 完结订单，点击图片放大查看'],
          ['远程控制', '管理员修改服务器文件即可改密码、推送 APP 更新'],
        ]),
      ]));

  // ===== 二、首次安装 =====
  pdf.addPage(pw.MultiPage(pageTheme: page, build: (c) => [
        h('二、首次安装与配置'),
        pw.SizedBox(height: 10),
        h2('2.1 安装 APK'),
        t('将 app-release.apk 传到手机 → 点击安装 → 设置中允许"安装未知应用"。'),
        pw.SizedBox(height: 10),
        h2('2.2 首次启动验证'),
        b('步骤一：系统授权'),
        t('首次打开 APP 弹出"系统安全验证"对话框，输入管理员提供的授权码（服务器 PIC/password.txt 中的数字）。'),
        b('步骤二：操作员姓名'),
        t('验证通过后弹出"操作员姓名"对话框，输入你的姓名（会记录到补货单中）。'),
        pw.SizedBox(height: 10),
        h2('2.3 配置门店登录'),
        t('1. 点底部"配置" → 在"门店 1"中填写：'),
        box('门店名称：总店\n门店账号：xxx（银豹工号登录页上的门店账号）\n员工工号：xxx\n工号密码：xxx'),
        t('2. 点"登录"按钮 → 成功后按钮变绿"已登录"。多门店依次配置。'),
        t('3. 所有修改自动保存，1.5 秒后静默写入本地。'),
        pw.SizedBox(height: 10),
        h2('2.4 配置补货服务器'),
        t('配置页上方"补货配置"中填写服务器地址（如 http://192.168.1.138），'
            '供货商列表默认已填入 100+ 个常用供货商。'),
        t('顶部标题栏右侧圆点变绿即表示服务器连接成功。'),
      ]));

  // ===== 三、日常使用 =====
  pdf.addPage(pw.MultiPage(pageTheme: page, build: (c) => [
        h('三、日常使用'),
        pw.SizedBox(height: 10),
        h2('3.1 查询库存'),
        b('操作流程：'),
        t('① 底部点"查询" → ② 输入条码 / 点扫码按钮 ▣ → ③ 点"查询多店" → ④ 查看结果'),
        pw.SizedBox(height: 6),
        t('查询结果页面（自上而下）：'),
        box('┌─────────────────────────┐\n'
            '│  商品名称 / 规格          │\n'
            '│  条码 · 供货商(绿色加粗) · 单位 │\n'
            '│  进货价  R11.50          │\n'
            '│  售价    R35.00 (大号红字) │\n'
            '├─────────────────────────┤\n'
            '│  总店: 152    分店: 88   │  ← 各店库存横向排列\n'
            '├─────────────────────────┤\n'
            '│  [补货] 按钮              │\n'
            '├─────────────────────────┤\n'
            '│  条码输入框    [扫码▣]    │\n'
            '│  [查询多店]               │\n'
            '├─────────────────────────┤\n'
            '│  登录状态: 总店·已登录 分店·未登录 │\n'
            '└─────────────────────────┘'),
        pw.SizedBox(height: 10),
        h2('3.2 补货（完整流程）'),
        t('① 查询商品 → ② 点"补货" → ③ 自动跳转补货Tab（条码和供货商已填入）'),
        t('④ 下拉可切换供货商 → ⑤ 修改数量和备注'),
        t('⑥ 点图片区 → 选"拍照"或"从相册选择" → 进入裁剪页 → 双指缩放/拖动 → 点右上角"确认"'),
        t('⑦ 点"提交补货" → 成功后自动回到查询页'),
        pw.SizedBox(height: 10),
        h2('3.3 顾客预定'),
        t('补货 Tab → 顶部点"顾客预定" → 填写电话(必填)、条码(选填)、数量、规格说明(必填) → 拍照 → 点"提交预定"'),
        pw.SizedBox(height: 10),
        h2('3.4 订单查询'),
        t('补货 Tab → 顶部点"订单查询" → 供货商下拉筛选 / 搜索框(搜电话、条码、说明) / 按时间或数量排序 → 点缩略图放大 → 点"完结"确认完成订单'),
      ]));

  // ===== 四、操作技巧 =====
  pdf.addPage(pw.MultiPage(pageTheme: page, build: (c) => [
        h('四、操作技巧与注意事项'),
        pw.SizedBox(height: 10),
        h2('4.1 手势导航'),
        table(['位置', '操作', '效果'], [
          ['主界面任意位置', '左右滑动', '切换 查询 ↔ 补货 ↔ 配置'],
          ['补货页 Tab 栏', '左右滑动', '切换 日常补货/顾客预定/订单查询'],
          ['日常补货右滑到底', '', '自动切到查询页'],
          ['订单查询左滑到底', '', '自动切到配置页'],
        ]),
        pw.SizedBox(height: 10),
        h2('4.2 服务器状态'),
        pw.Row(children: [
          g('🟢 绿色圆点 = '), t('WebServer 在线，补货/提交功能可用'),
        ]),
        pw.Row(children: [
          pw.Text('🔴 红色圆点 = ', style: pw.TextStyle(font: fb, fontSize: 11, color: PdfColors.red800)),
          t('WebServer 断网，仅可查询库存'),
        ]),
        t('点击圆点可手动重测连接状态，弹出 SnackBar 提示结果。'),
        pw.SizedBox(height: 10),
        h2('4.3 登录保持'),
        t('APP 每隔 15 分钟自动 ping 所有门店保持 Cookie 活跃，后台闲置后回到前台无需重新登录。'),
        t('如果登录已过期（如服务器重启），查询时会自动重新登录并重查，无需手动操作。'),
        pw.SizedBox(height: 10),
        h2('4.4 扫码技巧'),
        t('• 保持 10-20cm 距离，条码对准屏幕中央框内'),
        t('• 光线充足时识别率最高'),
        t('• 识别不到可手动输入条码数字'),
        t('• 如果 CameraX 对焦慢，可稍等几秒让镜头自动调整'),
      ]));

  // ===== 五、远程管理 =====
  pdf.addPage(pw.MultiPage(pageTheme: page, build: (c) => [
        h('五、远程管理（仅限管理员）'),
        pw.SizedBox(height: 10),
        t('管理员可直接编辑 WebServer 上的文件来控制所有已安装的 APP。'),
        pw.SizedBox(height: 10),
        h2('5.1 服务器文件'),
        box('D:\\WebServer2.3.1\\www\\PIC\\\n'
            '├── password.txt       系统密码（明文数字，如 21771737）\n'
            '├── app_version.txt    APP 版本号（纯数字，如 7）\n'
            '└── app-release.apk    最新安装包'),
        pw.SizedBox(height: 10),
        h2('5.2 改密码'),
        b('操作：修改 password.txt → 重启 WebServer → 生效'),
        t('所有已安装 APP 下次启动时检测到密码变更，弹出验证框要求输入新密码。'),
        pw.SizedBox(height: 10),
        h2('5.3 推送 APP 更新'),
        b('① 修改 pubspec.yaml 版本号（每次发布 +1）：'),
        box('version: 1.0.6+6  →  version: 1.0.7+7'),
        b('② 构建新 APK：'),
        box('cd pospal_stock_app\nflutter build apk --release'),
        b('③ 部署到服务器：'),
        box('copy build\\app\\outputs\\flutter-apk\\app-release.apk D:\\WebServer2.3.1\\www\\PIC\\\n'
            'echo 7 > D:\\WebServer2.3.1\\www\\PIC\\app_version.txt'),
        b('④ 重启 WebServer'),
        t('所有已安装 APP 下次启动时检测到新版本号，弹出强制更新对话框，'
            '点"立即更新"→ 手机浏览器下载 APK → 安装。'),
        t('更新弹窗同版本号只显示一次，避免循环提示。'),
      ]));

  // ===== 六、FAQ =====
  pdf.addPage(pw.MultiPage(pageTheme: page, build: (c) => [
        h('六、常见问题'),
        pw.SizedBox(height: 10),
        table(['问题', '原因 / 解决'], [
          ['补货服务器连不上', '检查电脑 IP 是否正确，WebServer 是否运行，防火墙是否放行'],
          ['工号登录失败', '先在电脑浏览器用工号登录网页版银豹，确认账号/工号/密码一致'],
          ['扫码识别率低', '保持 10-20cm 距离、光线充足；部分设备 CameraX 对焦需要时间'],
          ['提交补货成功但后台无数据', '检查供货商是否填写，照片是否上传成功'],
          ['APP 一直提示更新', '服务器上 app_version.txt 的值与 APK 实际版本号不一致'],
          ['HTTPS 地址不工作', 'APP 自动将 https:// 降级为 http://，本地无需 SSL 证书'],
          ['后台闲置后查询报错', '登录过期会触发自动重新登录，等待几秒即可，无需手动操作'],
          ['光标乱跳 / 编辑困难', '配置页已使用持久化控制器，光标不再自动跳末尾'],
          ['验证弹窗反复出现', '升级到 v1.0.6 后仅 password.txt 变更才触发，修改配置不弹窗'],
        ]),
      ]));

  // ===== 保存 =====
  final bytes = await pdf.save();
  final outFile = File('使用文档_v1.0.6.pdf');
  await outFile.writeAsBytes(bytes);
  print('PDF 已生成: ${outFile.absolute.path} (${bytes.length} bytes)');
}
