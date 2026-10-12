#!/bin/zsh
# Builds a fake tree with dummy data for screenshots and manual UI checks. Prints the env to use.
# usage: make-demo-tree.sh <dir> [normal|expiring|unnamed|switching|expanded]
# Nothing here touches real Claude, Chrome or session-sync files.
set -euo pipefail
D="${1:-${TMPDIR:-/tmp}/claude-accounts-demo}"
rm -rf "$D"; mkdir -p "$D"/{store/slots,Claude,Chrome/Default,sync,projects,Logs,Claude.app/Contents}
SCHEMA="CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR);
CREATE TABLE cookies(creation_utc INTEGER NOT NULL,host_key TEXT NOT NULL,top_frame_site_key TEXT NOT NULL,name TEXT NOT NULL,value TEXT NOT NULL,encrypted_value BLOB NOT NULL,path TEXT NOT NULL,expires_utc INTEGER NOT NULL,is_secure INTEGER NOT NULL,is_httponly INTEGER NOT NULL,last_access_utc INTEGER NOT NULL,has_expires INTEGER NOT NULL,is_persistent INTEGER NOT NULL,priority INTEGER NOT NULL,samesite INTEGER NOT NULL,source_scheme INTEGER NOT NULL,source_port INTEGER NOT NULL,last_update_utc INTEGER NOT NULL,source_type INTEGER NOT NULL,has_cross_site_ancestor INTEGER NOT NULL);"
mkcookies() { # file days
  local exp=$(( ($(date +%s) + $2*86400 + 11644473600) * 1000000 ))
  sqlite3 "$1" "$SCHEMA INSERT INTO cookies VALUES($exp,'.claude.ai','','sessionKeyV3','',X'00','/',$exp,1,1,$exp,1,1,1,0,2,443,$exp,0,0);"
}
A=11111111-aaaa-4aaa-8aaa-000000000001; B=22222222-bbbb-4bbb-8bbb-000000000002
C=33333333-cccc-4ccc-8ccc-000000000003; E=44444444-dddd-4ddd-8ddd-000000000004
mkcookies "$D/Claude/Cookies" 26
for x in "$B:40" "$C:5" "$E:20"; do id=${x%%:*}; mkdir -p "$D/store/slots/$id/desktop"; mkcookies "$D/store/slots/$id/desktop/Cookies" ${x##*:}; done
echo "{\"lastKnownAccountUuid\":\"$A\",\"locale\":\"en-US\"}" > "$D/Claude/config.json"
STATE="${2:-normal}"
iso() { date -u -v"$1" +%Y-%m-%dT%H:%M:%SZ; }
CR_EXP=+20d; RE_EXP=+24d; [[ "$STATE" == expiring ]] && { CR_EXP=+5d; RE_EXP=-1d; }
UNNAMED=""
if [[ "$STATE" == unnamed ]]; then
  U=55555555-eeee-4eee-8eee-000000000005; mkdir -p "$D/store/slots/$U/desktop"; mkcookies "$D/store/slots/$U/desktop/Cookies" 27
  UNNAMED=", {\"id\":\"$U\",\"label\":\"Unnamed account\",\"needsLabel\":true,\"colorIndex\":5,\"createdAt\":\"$(iso -1H)\",
   \"desktop\":{\"savedAt\":\"$(iso -1H)\",\"cookieExpiresAt\":\"$(iso +27d)\"}}"
fi
cat > "$D/store/accounts.json" <<JSON
[
 {"id":"$A","label":"team@example.com","colorIndex":0,"createdAt":"$(iso -30d)","lastUsedAt":"$(iso -1H)"},
 {"id":"$B","label":"me@example.com","colorIndex":1,"createdAt":"$(iso -30d)","lastUsedAt":"$(iso -2H)",
  "desktop":{"savedAt":"$(iso -2H)","cookieExpiresAt":"$(iso +12d)"}},
 {"id":"$C","label":"creators@example.com","colorIndex":3,"createdAt":"$(iso -30d)","lastUsedAt":"$(iso -3d)",
  "desktop":{"savedAt":"$(iso -3d)","cookieExpiresAt":"$(iso $CR_EXP)"}},
 {"id":"$E","label":"research@example.com","colorIndex":4,"createdAt":"$(iso -30d)","lastUsedAt":"$(iso -6d)",
  "desktop":{"savedAt":"$(iso -6d)","cookieExpiresAt":"$(iso $RE_EXP)"}}$UNNAMED
]
JSON
echo "$(date -v-12S '+%Y-%m-%d %H:%M:%S') stores=51 union_cards=2134 pending_writes=0 unwatched=0 secs=0.4" > "$D/sync/sync.log"
touch "$D/Logs/main.log"
chmod -R go-rwx "$D/store"
echo "CLAUDE_ACCOUNTS_ROOT=$D/store CLAUDE_USERDATA_DIR=$D/Claude CHROME_PROFILE_DIR=$D/Chrome/Default SESSION_SYNC_DIR=$D/sync CLAUDE_PROJECTS_DIR=$D/projects CLAUDE_LOGS_DIR=$D/Logs"
