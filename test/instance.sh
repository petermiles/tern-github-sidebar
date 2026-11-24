#!/bin/sh
# An isolated Tern instance for trying the plugin against test/fake-gh: its own config directory, daemon socket and
# HOME, with the fake `gh` first on PATH. Nothing here touches your own Tern windows or sessions, but `start` does
# open a window of its own, so run `stop` as soon as you are done.
#
#   test/instance.sh start           daemon + window, plugin linked
#   test/instance.sh shot out.png    print a PR link in the terminal, click it, save a screenshot (top bar cropped)
#   test/instance.sh ctl COMMAND...  any `tern ctl` command for the instance
#   test/instance.sh stop            close the window, stop the daemon
set -eu

here=$(cd "$(dirname "$0")" && pwd)
plugin=$(dirname "$here")
root=${GH_SIDEBAR_TEST_DIR:-/tmp/tern-github-sidebar-test}

isolate() {
	for name in $(env | grep -o '^TERN_[A-Z_]*'); do unset "$name"; done
	unset GH_TOKEN GITHUB_TOKEN GH_HOST
	export TERN_CONFIG_DIR="$root/cfg" TERN_DAEMON_SOCKET="$root/daemon.sock"
	export HOME="$root/home" PATH="$root/bin:$PATH"
}

stop() {
	isolate
	tern ctl --control "$root/ctl.sock" quit >/dev/null 2>&1 || true
	# The window can take its 10 s grace to end; the daemon and the fake gh watchers follow it.
	for _ in 1 2 3 4 5 6 7 8 9 10; do
		pkill -f "tern daemon --socket $root/daemon.sock" 2>/dev/null || true
		pkill -f "$root/bin/gh" 2>/dev/null || true
		pgrep -f "$root" >/dev/null 2>&1 || break
		sleep 1
	done
}

case "${1:-}" in
start)
	stop
	rm -rf "$root"
	mkdir -p "$root/cfg" "$root/home" "$root/bin"
	ln -s "$here/fake-gh" "$root/bin/gh"
	isolate
	cd "$root"
	nohup tern daemon --socket "$root/daemon.sock" >"$root/daemon.log" 2>&1 &
	sleep 1
	tern plugin link "$plugin"
	nohup tern --control "$root/ctl.sock" "$root" >"$root/window.log" 2>&1 &
	for _ in 1 2 3 4 5 6 7 8 9 10; do
		[ -S "$root/ctl.sock" ] && break
		sleep 1
	done
	sleep 2
	tern plugin list | grep github-sidebar
	;;
shot)
	out=${2:?usage: instance.sh shot out.png}
	isolate
	cd "$root"
	scenario="$root/shot.txt"
	cat >"$scenario" <<EOF
size 1280 800
wait 1500
key Escape
wait 400
key Escape
wait 400
run "PS1='\$ '; clear; echo 'Opened the rate limiter for review:'; $here/link.sh https://github.com/acme/api/pull/42 'acme/api#42 Add token bucket rate limiter'"
wait 800
click 40 74 meta
wait 7000
shot readme
EOF
	tern ctl --control "$root/ctl.sock" --file "$scenario" >/dev/null
	png="$root/target/shots/tern/live/readme.png"
	if command -v ffmpeg >/dev/null 2>&1; then
		ffmpeg -y -loglevel error -i "$png" -vf "crop=2560:1508:0:92,scale=1600:-1" "$out"
	else
		cp "$png" "$out"
	fi
	echo "$out"
	;;
ctl)
	shift
	isolate
	exec tern ctl --control "$root/ctl.sock" "$@"
	;;
stop)
	stop
	;;
*)
	sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
	exit 2
	;;
esac
