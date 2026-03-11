import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:rustyfoot_hmi/bank.dart';

final log = Logger('Banks');

class BanksWidget extends StatefulWidget {
  final int selectedBankId;
  final void Function(Bank bank) onBankSelected;

  const BanksWidget({
    super.key,
    required this.selectedBankId,
    required this.onBankSelected,
  });

  @override
  State<BanksWidget> createState() => _BanksWidgetState();
}

class _BanksWidgetState extends State<BanksWidget> {
  List<Bank> _banks = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadBanks();
  }

  Future<void> _loadBanks() async {
    final banks = await Bank.loadAll();
    setState(() {
      _banks = banks;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_banks.isEmpty) {
      return const Center(child: Text('No banks available'));
    }

    return ListView.builder(
      itemCount: _banks.length,
      itemBuilder: (context, index) {
        final bank = _banks[index];
        final isSelected = bank.id == widget.selectedBankId;

        return ListTile(
          leading: Icon(
            bank.id == 1 ? Icons.library_music : Icons.folder,
            color: isSelected ? Theme.of(context).colorScheme.primary : null,
          ),
          title: Text(
            bank.title,
            style: TextStyle(
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              color: isSelected ? Theme.of(context).colorScheme.primary : null,
            ),
          ),
          subtitle: bank.id == 1
              ? const Text('All available pedalboards')
              : Text('${bank.pedalboardBundles.length} pedalboards'),
          trailing: isSelected
              ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary)
              : null,
          onTap: () {
            log.info('Selected bank: ${bank.title} (id=${bank.id})');
            widget.onBankSelected(bank);
          },
        );
      },
    );
  }
}
