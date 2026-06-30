# 银豹多店库存查询 - Android App

基于 Flutter 开发的独立 Android App，直接与银豹后台通信，不需要电脑运行 Node.js 服务。

## 功能

- **多门店配置**：支持 1~10 个门店，密码加密存储
- **工号登录**：自动解析登录页面，支持多种登录方案
- **条码查询**：摄像头扫码 + 手动输入
- **多店库存**：并发查询所有门店，横向展示库存
- **智能字段匹配**：自动识别库存、名称、单位等字段
- **查询耗时显示**：直观显示搜索用时
- **多条结果提示**：当条码匹配多条商品时给出提示
- **调试面板**：显示原始 API 返回字段

## 开发环境搭建

### 1. 安装 Flutter SDK

从 https://docs.flutter.dev/get-started/install 下载 Flutter SDK。

### 2. 配置环境变量

将 Flutter 的 `bin` 目录添加到系统 PATH 环境变量。

### 3. 验证安装

```bash
flutter doctor
```

确保 Android SDK 已安装且 `flutter doctor` 全部通过。

### 4. 获取依赖

```bash
cd pospal_stock_app
flutter pub get
```

### 5. 运行

```bash
# 连接 Android 设备或启动模拟器
flutter run
```

### 6. 打包 APK

```bash
flutter build apk --release
```

APK 文件位于：`build/app/outputs/flutter-apk/app-release.apk`

## 项目结构

```
pospal_stock_app/
├── lib/
│   ├── main.dart                    # 入口
│   ├── app.dart                     # App 配置 + 主题
│   ├── models/
│   │   ├── store_config.dart        # 门店配置模型
│   │   ├── product_result.dart      # 商品查询结果模型
│   │   └── login_session.dart       # 登录会话模型
│   ├── services/
│   │   ├── config_service.dart      # 配置持久化
│   │   ├── session_manager.dart     # Cookie 会话管理
│   │   ├── login_service.dart       # 工号登录
│   │   └── query_service.dart       # 条码查询
│   ├── pages/
│   │   ├── home_page.dart           # 主页（Tab 切换）
│   │   ├── settings_page.dart       # 配置管理页
│   │   ├── query_page.dart          # 查询页（扫码+输入）
│   │   └── result_page.dart         # 查询结果页
│   ├── widgets/
│   │   ├── store_card.dart          # 门店结果卡片
│   │   ├── scanner_view.dart        # 扫码器组件
│   │   ├── login_button.dart        # 登录按钮组件
│   │   └── config_form.dart         # 配置表单组件
│   └── utils/
│       ├── html_parser.dart         # HTML 解析（移植 signin-parse.js）
│       ├── product_parser.dart      # 商品数据解析（移植 product-utils.js）
│       └── constants.dart           # 常量
├── android/
├── test/
├── pubspec.yaml
└── README.md
```

## 核心逻辑移植说明

本 App 的核心逻辑移植自现有 Node.js Web 项目：

| JS 源文件 | Dart 目标文件 | 说明 |
|-----------|--------------|------|
| `server/signin-parse.js` | `lib/utils/html_parser.dart` | 登录页 HTML 解析 |
| `server/product-utils.js` | `lib/utils/product_parser.dart` | 商品数据标准化 |
| `server/pospal.js` (loginStoreHttp) | `lib/services/login_service.dart` | 工号登录 |
| `server/pospal.js` (queryByBarcode) | `lib/services/query_service.dart` | 条码查询 |
| `server/pospal.js` (queryAllStores) | `lib/services/query_service.dart` | 多店并发查询 |

## 依赖库

- `http` - HTTP 客户端
- `cookie_jar` - Cookie 管理（预留）
- `shared_preferences` - 本地配置存储
- `flutter_secure_storage` - 密码加密存储
- `mobile_scanner` - 条码扫描（Google ML Kit）
