#!/usr/bin/env python3
"""Upload a file to Google Drive using either a service account or user OAuth."""

from __future__ import annotations

import argparse
import mimetypes
import os
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

SCOPES = ["https://www.googleapis.com/auth/drive.file"]


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "path",
        type=Path,
        help="Local file to upload",
    )
    parser.add_argument(
        "--credentials",
        default=os.environ.get("GOOGLE_APPLICATION_CREDENTIALS"),
        help="Path to the credentials JSON (service account key or OAuth client secrets)",
    )
    parser.add_argument(
        "--folder-id",
        help="Optional Drive folder ID to receive the file",
    )
    parser.add_argument(
        "--name",
        help="Filename to use on Drive (defaults to the local filename)",
    )
    parser.add_argument(
        "--mime-type",
        help="Explicit MIME type; detected automatically when omitted",
    )
    parser.add_argument(
        "--replace",
        action="store_true",
        help="Replace an existing file with the same Drive name (within the same folder)",
    )
    parser.add_argument(
        "--auth",
        choices=("service-account", "oauth"),
        default="service-account",
        help="Authentication mode: service-account (default) or oauth for personal Drive",
    )
    parser.add_argument(
        "--token",
        help="For OAuth mode, path to store the refresh token (defaults to <credentials>.token.json)",
    )
    parser.add_argument(
        "--keep-days",
        type=int,
        help="Delete remote files older than this many days (within the same folder)",
    )
    parser.add_argument(
        "--keep-prefix",
        help="Optional name prefix filter when pruning remote files (defaults to uploaded file prefix)",
    )
    return parser.parse_args(argv)


def detect_mime(path: Path, override: str | None) -> str:
    if override:
        return override
    mime, _ = mimetypes.guess_type(path.as_posix())
    return mime or "application/octet-stream"


def load_google_clients():
    try:
        from google.oauth2.service_account import Credentials as ServiceAccountCredentials
        from googleapiclient.discovery import build
        from googleapiclient.http import MediaFileUpload
        from google_auth_oauthlib.flow import InstalledAppFlow
        from google.oauth2.credentials import Credentials as UserCredentials
        from google.auth.transport.requests import Request
    except ModuleNotFoundError as exc:  # pragma: no cover - dependency guard
        missing = "google-api-python-client"
        print(
            f"Missing dependencies: install {missing} (and google-auth) before running this script.",
            file=sys.stderr,
        )
        raise
    return (
        ServiceAccountCredentials,
        build,
        MediaFileUpload,
        InstalledAppFlow,
        UserCredentials,
        Request,
    )


def build_service(creds_path_str: str | None, credentials_cls, build_fn) -> "Resource":
    if not creds_path_str:
        raise FileNotFoundError(
            "Provide a valid service-account key with --credentials or GOOGLE_APPLICATION_CREDENTIALS"
        )
    creds_path = Path(creds_path_str)
    if not creds_path.is_file():
        raise FileNotFoundError(
            f"Credentials file not found: {creds_path}" 
        )
    credentials = credentials_cls.from_service_account_file(creds_path.as_posix(), scopes=SCOPES)
    return build_fn("drive", "v3", credentials=credentials, cache_discovery=False)


def build_service_oauth(creds_path_str: str | None, token_path: Path | None, flow_cls, user_credentials_cls, request_cls, build_fn) -> "Resource":
    if not creds_path_str:
        raise FileNotFoundError("Provide an OAuth client secrets JSON via --credentials")

    creds_path = Path(creds_path_str)
    if not creds_path.is_file():
        raise FileNotFoundError(f"Client secrets file not found: {creds_path}")

    if token_path is None:
        token_path = creds_path.with_suffix(creds_path.suffix + ".token.json")

    creds = None
    if token_path.exists():
        creds = user_credentials_cls.from_authorized_user_file(token_path.as_posix(), SCOPES)

    if not creds or not creds.valid:
        if creds and creds.expired and creds.refresh_token:
            creds.refresh(request_cls())
        else:
            flow = flow_cls.from_client_secrets_file(creds_path.as_posix(), SCOPES)
            creds = flow.run_local_server(port=0)
        token_path.parent.mkdir(parents=True, exist_ok=True)
        token_path.write_text(creds.to_json())

    return build_fn("drive", "v3", credentials=creds, cache_discovery=False)


def find_existing(service, name: str, folder_id: str | None) -> list[dict]:
    query_parts = ["name = \"{}\"".format(name.replace("\"", "\\\""))]
    if folder_id:
        query_parts.append(f"'{folder_id}' in parents")
    else:
        query_parts.append("'root' in parents")
    query_parts.append("trashed = false")
    query = " and ".join(query_parts)
    response = (
        service.files()
        .list(q=query, spaces="drive", fields="files(id, name)")
        .execute()
    )
    return response.get("files", [])


def delete_files(service, files: list[dict]) -> None:
    for entry in files:
        service.files().delete(fileId=entry["id"]).execute()


def upload_file(service, path: Path, *, folder_id: str | None, name: str, mime_type: str, media_cls) -> dict:
    metadata = {"name": name}
    if folder_id:
        metadata["parents"] = [folder_id]
    media = media_cls(path.as_posix(), mimetype=mime_type, resumable=True)
    request = service.files().create(body=metadata, media_body=media, fields="id, webViewLink, webContentLink")
    return request.execute()


def default_prefix(name: str) -> str:
    for sep in ("_", "."):
        if sep in name:
            return name.split(sep)[0]
    return name


def cleanup_remote_files(service, *, folder_id: str | None, keep_days: int | None, prefix: str | None) -> None:
    if keep_days is None or keep_days < 0:
        return

    cutoff = datetime.now(timezone.utc) - timedelta(days=keep_days)
    cutoff_iso = cutoff.isoformat(timespec="seconds")

    query_parts = ["trashed = false", f"createdTime < '{cutoff_iso}'"]
    if folder_id:
        query_parts.append(f"'{folder_id}' in parents")
    else:
        query_parts.append("'root' in parents")
    if prefix:
        safe_prefix = prefix.replace("'", "\\'")
        query_parts.append(f"name contains '{safe_prefix}'")

    query = " and ".join(query_parts)
    page_token = None
    while True:
        response = (
            service.files()
            .list(
                q=query,
                spaces="drive",
                fields="files(id, name, createdTime)",
                pageToken=page_token,
                pageSize=1000,
            )
            .execute()
        )
        files = response.get("files", [])
        for entry in files:
            service.files().delete(fileId=entry["id"]).execute()
            print(
                f"Deleted remote file {entry['name']} created {entry['createdTime']} (older than {keep_days} day(s))"
            )
        page_token = response.get("nextPageToken")
        if not page_token:
            break


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if not args.path.is_file():
        print(f"Source file not found: {args.path}", file=sys.stderr)
        return 1

    (
        ServiceAccountCredentials,
        build_fn,
        MediaFileUpload,
        InstalledAppFlow,
        UserCredentials,
        RequestCls,
    ) = load_google_clients()

    if args.auth == "service-account":
        service = build_service(args.credentials, ServiceAccountCredentials, build_fn)
    else:
        token_path = Path(args.token) if args.token else None
        service = build_service_oauth(
            args.credentials,
            token_path,
            InstalledAppFlow,
            UserCredentials,
            RequestCls,
            build_fn,
        )
    mime_type = detect_mime(args.path, args.mime_type)
    drive_name = args.name or args.path.name

    if args.replace:
        existing = find_existing(service, drive_name, args.folder_id)
        if existing:
            delete_files(service, existing)

    result = upload_file(
        service,
        args.path,
        folder_id=args.folder_id,
        name=drive_name,
        mime_type=mime_type,
        media_cls=MediaFileUpload,
    )
    web_view = result.get("webViewLink")
    web_content = result.get("webContentLink")

    print(f"Uploaded file ID: {result['id']}")
    if web_view:
        print(f"View link: {web_view}")
    if web_content:
        print(f"Download link: {web_content}")

    prefix = args.keep_prefix
    if args.keep_days is not None and prefix is None:
        prefix = default_prefix(drive_name)
    cleanup_remote_files(
        service,
        folder_id=args.folder_id,
        keep_days=args.keep_days,
        prefix=prefix,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
