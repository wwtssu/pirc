import { opendir, mkdir, stat } from "node:fs/promises";
import path from "node:path";

// Only the directory explicitly requested is opened. In particular, don't stat
// child directories or follow symlinks into protected folders/cloud volumes.
const [
  home,
  requested = "",
  cursor = "",
  hidden = "false",
  operation = "browse",
  name = "",
] = process.argv.slice(2);
const fail = (code, detail) => ({ type: "error", code, detail });
async function browse() {
  let folder = requested || home;
  if (folder === "~") folder = home;
  else if (folder.startsWith(`~${path.sep}`))
    folder = path.join(home, folder.slice(2));
  if (
    !path.isAbsolute(folder) ||
    folder.includes("\0") ||
    Buffer.byteLength(folder) > 4096
  )
    return fail("INVALID_DIRECTORY", "Enter an absolute directory path on the device");
  folder = path.normalize(folder);
  if (operation === "prepare") {
    try {
      const info = await stat(folder);
      if (!info.isDirectory()) return fail("INVALID_DIRECTORY", "Working directory path is not a directory.");
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
      if (name !== "true") return { type: "working_directory_missing", path: folder };
      await mkdir(folder, { recursive: true });
      if (!(await stat(folder)).isDirectory()) return fail("INVALID_DIRECTORY", "Working directory path is not a directory.");
    }
    return { type: "working_directory_ready", path: folder };
  }
  if (operation === "create") {
    if (
      !name.trim() ||
      name === "." ||
      name === ".." ||
      /[\\/\0]/.test(name) ||
      Buffer.byteLength(name) > 255
    ) {
      return fail(
        "INVALID_DIRECTORY_NAME",
        "Enter a single folder name without / or backslash, at most 255 bytes",
      );
    }
    const target = path.join(folder, name);
    if (Buffer.byteLength(target) > 4096)
      return fail("INVALID_DIRECTORY", "Directory path is too long. Choose another location.");
    // Exclusive and non-recursive: never overwrite an existing file/folder,
    // and never create unspecified parent directories.
    await mkdir(target);
    return { type: "directory_created", path: target };
  }
  const entries = [];
  const dir = await opendir(folder);
  for await (const entry of dir) {
    if (hidden === "true" || !entry.name.startsWith(".")) {
      entries.push({
        name: entry.name,
        path: path.join(folder, entry.name),
        is_directory: entry.isDirectory(),
      });
    }
    if (entries.length > 100_000)
      return fail(
        "DIRECTORY_TOO_LARGE",
        "Too many entries in this directory. Enter a more specific path.",
      );
  }
  // The cursor includes the group so pagination stays stable with folders first.
  const key = (entry) => `${entry.is_directory ? "0" : "1"}/${entry.name}`;
  entries.sort((a, b) => key(a) < key(b) ? -1 : key(a) > key(b) ? 1 : 0);
  const candidates = entries.filter((entry) => !cursor || key(entry) > cursor);
  const page = [];
  let bytes = 0;
  for (const entry of candidates) {
    bytes += Buffer.byteLength(JSON.stringify(entry));
    if (page.length >= 200 || bytes > 512 * 1024) break;
    page.push(entry);
  }
  const parent = path.dirname(folder);
  return {
    type: "directory_list",
    path: folder,
    parent: parent === folder ? null : parent,
    home,
    entries: page,
    next_cursor:
      page.length < candidates.length ? key(page.at(-1)) : null,
  };
}
try {
  process.stdout.write(JSON.stringify(await browse()));
} catch (error) {
  let detail, code;
  if (["EPERM", "EACCES"].includes(error.code)) {
    code = "DIRECTORY_PERMISSION_DENIED";
    detail =
      process.platform === "darwin"
        ? "Directory access is not allowed. On the device, open System Settings → Privacy & Security → Files and Folders and grant access to the server application, or choose another directory."
        : "Directory access is not allowed. Check permissions on the device or choose another directory.";
  } else if (error.code === "EEXIST") {
    code = "DIRECTORY_EXISTS";
    detail = "A file or folder with this name already exists. Choose another name or refresh the directory.";
  } else if (["ENAMETOOLONG", "EINVAL"].includes(error.code)) {
    code = "INVALID_DIRECTORY_NAME";
    detail = "Folder name is invalid or too long. Choose another name.";
  } else if (["ENOENT", "ENOTDIR"].includes(error.code)) {
    code = "DIRECTORY_NOT_FOUND";
    detail = "Directory does not exist or is unavailable. Check the path or choose another directory.";
  } else {
    code = "DIRECTORY_UNAVAILABLE";
    detail =
      operation === "create"
        ? "Creation is unconfirmed. Close and refresh the directory before retrying."
        : "Unable to read this directory. Retry or choose another directory.";
  }
  process.stdout.write(JSON.stringify(fail(code, detail)));
}
