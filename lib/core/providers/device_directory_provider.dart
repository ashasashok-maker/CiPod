import 'package:classipod/core/models/device_directory.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

final deviceDirectoryProvider = FutureProvider<DeviceDirectory>((ref) async {
  final documentsDirectory = await getApplicationDocumentsDirectory();
  return DeviceDirectory(documentsDirectory: documentsDirectory);
});
