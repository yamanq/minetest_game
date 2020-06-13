#!/bin/bash -e
p=$PWD
if ! [[ -f "$p/findtext.lua" && -f "$p/updatetext.lua" ]]; then
	echo "Missing findtext.lua and updatetext.lua"
	exit 1
fi

luafile=$(mktemp -u).lua
trap 'rm -f $luafile' EXIT

if [ ! -d mods ]; then
	echo "Current directory needs to be the repository root"
	exit 1
fi
pushd mods
for name in *; do
	echo
	[ -d "$name/locale" ] || { echo "Skipping $name (no locale folder)"; continue; }

	echo "Updating template for $name"
	printf 'local S = minetest.get_translator("%s")\n' "$name" >"$luafile"
	cat $(find "$name/" -name '*.lua') >>"$luafile"
	lua "$p/findtext.lua" -o "$name/locale/template.txt" "$luafile"

	echo "Updating translations for $name"
	pushd "$name/locale"
	for tl in *.tr; do
		echo "    $tl"
		lua "$p/updatetext.lua" template.txt "$tl" >/dev/null
		sed '2,999s/^# textdomain:.*//' "$tl" -i # delete duplicate textdomain line
	done
	popd
done
popd

echo "All done."
exit 0
