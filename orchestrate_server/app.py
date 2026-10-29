import base64
import errno
import fcntl
import os
import pty
import select
import shutil
import struct
import subprocess
import termios
from typing import Iterator

from flask import Flask, Response, jsonify, render_template, request

app = Flask(__name__)
app.config["FILE_EXPLORER_ROOT"] = os.path.realpath(
    os.environ.get("FILE_EXPLORER_ROOT", "/")
)


def _terminal_size(name: str, default: int, minimum: int, maximum: int) -> int:
    value = request.args.get(name, default=str(default))
    try:
        size = int(value)
    except ValueError as error:
        raise ValueError(f"{name} must be an integer.") from error
    if not minimum <= size <= maximum:
        raise ValueError(f"{name} must be between {minimum} and {maximum}.")
    return size


def _start_btop(columns: int, rows: int) -> tuple[subprocess.Popen[bytes], int]:
    btop_path = shutil.which("btop")
    if btop_path is None:
        raise FileNotFoundError("btop is not installed or is not on PATH.")

    master_fd, slave_fd = pty.openpty()
    try:
        fcntl.ioctl(
            slave_fd,
            termios.TIOCSWINSZ,
            struct.pack("HHHH", rows, columns, 0, 0),
        )
        environment = os.environ.copy()
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        process = subprocess.Popen(
            [btop_path, "--force-utf"],
            stdin=slave_fd,
            stdout=slave_fd,
            stderr=slave_fd,
            env=environment,
            close_fds=True,
            start_new_session=True,
        )
    except Exception:
        os.close(master_fd)
        raise
    finally:
        os.close(slave_fd)

    return process, master_fd


def _stream_terminal(process: subprocess.Popen[bytes], master_fd: int) -> Iterator[str]:
    try:
        while True:
            readable, _, _ = select.select([master_fd], [], [], 1)
            if readable:
                try:
                    output = os.read(master_fd, 8192)
                except OSError as error:
                    if error.errno == errno.EIO:
                        break
                    raise
                if not output:
                    break
                encoded = base64.b64encode(output).decode("ascii")
                yield f"data: {encoded}\n\n"
            elif process.poll() is not None:
                break
            else:
                yield ": keepalive\n\n"
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        os.close(master_fd)


@app.get("/")
def index() -> str:
    return render_template("index.html")


@app.get("/api/files")
def list_files() -> Response | tuple[Response, int]:
    root = os.path.realpath(app.config["FILE_EXPLORER_ROOT"])
    requested_path = request.args.get("path", root)
    if "\0" in requested_path:
        return jsonify(error="The requested path is invalid."), 400

    directory = os.path.realpath(os.path.abspath(requested_path))
    if os.path.commonpath((root, directory)) != root:
        return jsonify(error="The requested path is outside the explorer root."), 403

    try:
        entries = []
        with os.scandir(directory) as listing:
            for entry in listing:
                if entry.is_symlink():
                    entry_type = "symlink"
                elif entry.is_dir(follow_symlinks=False):
                    entry_type = "directory"
                else:
                    entry_type = "file"
                try:
                    metadata = entry.stat(follow_symlinks=False)
                    size = metadata.st_size if entry_type == "file" else None
                    modified = metadata.st_mtime
                except OSError:
                    size = None
                    modified = None
                entries.append(
                    {
                        "name": entry.name,
                        "path": os.path.join(directory, entry.name),
                        "type": entry_type,
                        "size": size,
                        "modified": modified,
                    }
                )
    except PermissionError:
        return jsonify(error="Permission denied for this directory."), 403
    except FileNotFoundError:
        return jsonify(error="This directory does not exist."), 404
    except NotADirectoryError:
        return jsonify(error="The requested path is not a directory."), 404
    except OSError:
        app.logger.exception("Unable to list directory %s", directory)
        return jsonify(error="Unable to list this directory."), 500

    entries.sort(key=lambda entry: (entry["type"] != "directory", entry["name"].casefold()))
    parent = os.path.dirname(directory) if directory != root else None
    return jsonify(path=directory, parent=parent, entries=entries)


@app.get("/api/terminal")
def terminal_stream() -> Response | tuple[Response, int]:
    try:
        columns = _terminal_size("cols", 120, 40, 300)
        rows = _terminal_size("rows", 36, 12, 100)
    except ValueError as error:
        return jsonify(error=str(error)), 400

    try:
        process, master_fd = _start_btop(columns, rows)
    except (FileNotFoundError, OSError) as error:
        app.logger.error("Unable to start btop: %s", error)
        return jsonify(error=str(error)), 503

    return Response(
        _stream_terminal(process, master_fd),
        mimetype="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",
        },
    )


if __name__ == "__main__":
    app.run(
        host=os.environ.get("HOST", "127.0.0.1"),
        port=int(os.environ.get("PORT", "5000")),
        debug=False,
        threaded=True,
    )