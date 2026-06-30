import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

/// APP 版本更新服务
class UpdateService {
  /// 规范化 URL：https → http，补前缀，去斜杠
  static String normalizeUrl(String serverUrl) {
    var url = serverUrl.trim();
    if (url.isEmpty) return url;
    if (url.startsWith('https://')) {
      url = 'http://${url.substring(8)}';
    }
    if (!url.startsWith('http://')) {
      url = 'http://$url';
    }
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  /// 获取当前 APP 版本号（build number）
  Future<int> get currentVersion async {
    final info = await PackageInfo.fromPlatform();
    return int.tryParse(info.buildNumber) ?? 1;
  }

  /// 获取当前 APP 版本名称（如 1.0.4）
  Future<String> get versionName async {
    final info = await PackageInfo.fromPlatform();
    return info.version;
  }

  /// 检查更新（返回新版本号，0 表示已是最新）
  Future<int> checkUpdate(String serverUrl) async {
    final url = normalizeUrl(serverUrl);
    if (url.isEmpty) return 0;

    try {
      final uri = Uri.parse('$url/PIC/app_version.txt');
      final response = await http.get(uri).timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        final remoteVer = int.tryParse(response.body.trim()) ?? 0;
        final current = await currentVersion;
        if (remoteVer > current) return remoteVer;
      }
    } catch (_) {}
    return 0;
  }

  /// 打开浏览器下载 APK
  Future<bool> openDownloadPage(String serverUrl) async {
    final baseUrl = normalizeUrl(serverUrl);
    final url = '$baseUrl/PIC/app-release.apk';
    final uri = Uri.parse(url);
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}
