/// Downloads and archives: the "download and add" half of installing a
/// package, shared by `just` and its plugins.
///
/// - [HttpFetcher]: HTTPS only (every redirect too), polite retries,
///   limits, every failure a [FetchException], and [CachedText] that still
///   reads offline.
/// - [DownloadCache] and [checkPinned]: downloads pinned by size and
///   SHA-256, kept per user.
/// - [GitHubRepo]: where a repository's release files are, without the
///   rate-limited GitHub API.
/// - [ZipArchive] reads a zip, refusing anything a tool should never unpack
///   (paths outside the folder, links, ZIP64, bombs); [ZipWriter] writes
///   one the same way every time. [SafePaths] holds the path rules both
///   follow.
/// - [CancelToken] stops any of it.
library;

export 'src/archive/safe_paths.dart';
export 'src/archive/zip_reader.dart';
export 'src/archive/zip_writer.dart';
export 'src/fetch/cancel.dart';
export 'src/fetch/download_cache.dart';
export 'src/fetch/github_release.dart';
export 'src/fetch/http_fetcher.dart';
