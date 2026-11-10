import 'dart:convert';
import 'dart:io';

/// Resolves a package from existing workspace metadata without refreshing pub.
String? resolvedPackagePath(Directory repoRoot, String package) {
  final config = File('${repoRoot.path}/.dart_tool/package_config.json');
  if (!config.existsSync()) return null;
  final decoded = jsonDecode(config.readAsStringSync());
  if (decoded case {'packages': final List<Object?> packages}) {
    for (final entry in packages) {
      if (entry case {
        'name': final String name,
        'rootUri': final String uri,
      } when name == package) {
        final root = Uri.parse(uri);
        return (root.isAbsolute ? root : config.parent.uri.resolve(uri))
            .toFilePath();
      }
    }
  }
  return null;
}
