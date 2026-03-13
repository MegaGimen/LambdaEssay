import 'package:flutter/material.dart';
import 'models.dart';

class UpstreamDialog extends StatefulWidget {
  final List<Branch> localBranches;
  final List<Branch> remoteBranches;
  final Function(String local, String? remote) onSave;

  const UpstreamDialog({
    super.key,
    required this.localBranches,
    required this.remoteBranches,
    required this.onSave,
  });

  @override
  State<UpstreamDialog> createState() => _UpstreamDialogState();
}

class _UpstreamDialogState extends State<UpstreamDialog> {
  late Map<String, String?> _mappings;

  @override
  void initState() {
    super.initState();
    _mappings = {
      for (var b in widget.localBranches) b.name: b.upstream,
    };
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('设置分支关联 (Upstream)'),
      content: SizedBox(
        width: 600,
        height: 500,
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 16.0),
              child: Text('在此可以手动查看和修改本地分支与远程分支的对应关系。',
                  style: TextStyle(color: Colors.grey, fontSize: 13)),
            ),
            Expanded(
              child: ListView.separated(
                itemCount: widget.localBranches.length,
                separatorBuilder: (_, __) => const Divider(),
                itemBuilder: (context, index) {
                  final local = widget.localBranches[index];
                  final currentUpstream = _mappings[local.name];

                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8.0),
                    child: Row(
                      children: [
                        Expanded(
                          flex: 2,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(local.displayName,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold)),
                              const SizedBox(height: 4),
                              Text(
                                currentUpstream != null
                                    ? '当前关联: $currentUpstream'
                                    : '未关联远程分支',
                                style: TextStyle(
                                    fontSize: 12,
                                    color: currentUpstream != null
                                        ? Colors.green
                                        : Colors.orange),
                              ),
                            ],
                          ),
                        ),
                        const Icon(Icons.arrow_forward,
                            size: 16, color: Colors.grey),
                        const SizedBox(width: 16),
                        Expanded(
                          flex: 3,
                          child: DropdownButtonFormField<String>(
                            isExpanded: true,
                            decoration: const InputDecoration(
                              isDense: true,
                              contentPadding: EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 8),
                              border: OutlineInputBorder(),
                            ),
                            value: widget.remoteBranches
                                    .any((rb) => rb.name == currentUpstream)
                                ? currentUpstream
                                : null,
                            hint: const Text('选择远程分支'),
                            items: [
                              const DropdownMenuItem<String>(
                                value: null,
                                child: Text('无 (取消关联)',
                                    style: TextStyle(color: Colors.red)),
                              ),
                              ...widget.remoteBranches
                                  .map((rb) => DropdownMenuItem<String>(
                                        value: rb.name,
                                        child: Text(rb.name,
                                            overflow: TextOverflow.ellipsis),
                                      )),
                            ],
                            onChanged: (val) {
                              setState(() {
                                _mappings[local.name] = val;
                              });
                              widget.onSave(local.name, val);
                            },
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
