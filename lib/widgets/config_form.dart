import 'package:flutter/material.dart';
import '../models/store_config.dart';
import '../utils/constants.dart';

/// 门店配置表单（持久化控制器，不跳光标）
class ConfigForm extends StatefulWidget {
  final int index;
  final StoreConfig config;
  final bool canRemove;
  final ValueChanged<StoreConfig> onChanged;
  final VoidCallback? onRemove;

  const ConfigForm({
    super.key,
    required this.index,
    required this.config,
    required this.canRemove,
    required this.onChanged,
    this.onRemove,
  });

  @override
  State<ConfigForm> createState() => _ConfigFormState();
}

class _ConfigFormState extends State<ConfigForm> {
  late final _nameCtrl = TextEditingController(text: widget.config.name);
  late final _acctCtrl = TextEditingController(text: widget.config.account);
  late final _jobCtrl = TextEditingController(text: widget.config.cashierJobNumber);
  late final _pwdCtrl = TextEditingController(text: widget.config.password);

  @override
  void dispose() {
    _nameCtrl.dispose();
    _acctCtrl.dispose();
    _jobCtrl.dispose();
    _pwdCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppConstants.radiusMd)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.store, size: 18, color: AppConstants.primaryColor),
            const SizedBox(width: 6),
            Text('门店 ${widget.index + 1}', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            const Spacer(),
            if (widget.canRemove && widget.onRemove != null)
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 20, color: AppConstants.errorColor),
                onPressed: widget.onRemove, tooltip: '删除此门店',
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                padding: EdgeInsets.zero,
              ),
          ]),
          const SizedBox(height: 10),
          _f('门店名称', _nameCtrl, '例如：总店', (v) => widget.onChanged(widget.config.copyWith(name: v))),
          const SizedBox(height: 8),
          _f('门店账号', _acctCtrl, '银豹门店账号', (v) => widget.onChanged(widget.config.copyWith(account: v))),
          const SizedBox(height: 8),
          _f('员工工号', _jobCtrl, '例如：1001', (v) => widget.onChanged(widget.config.copyWith(cashierJobNumber: v)), keyboardType: TextInputType.number),
          const SizedBox(height: 8),
          _f('工号密码', _pwdCtrl, '工号登录密码', (v) => widget.onChanged(widget.config.copyWith(password: v)), obscureText: true),
        ]),
      ),
    );
  }

  Widget _f(String label, TextEditingController ctrl, String hint, ValueChanged<String> onChanged,
      {bool obscureText = false, TextInputType keyboardType = TextInputType.text}) {
    return TextField(
      controller: ctrl,
      decoration: InputDecoration(labelText: label, hintText: hint, isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppConstants.radiusSm)),
      ),
      obscureText: obscureText, keyboardType: keyboardType,
      style: const TextStyle(fontSize: 14),
      onChanged: onChanged,
    );
  }
}
