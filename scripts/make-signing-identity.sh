#!/bin/sh
# Makes a self-signed code-signing identity, "deskdash local signing", in your login keychain, which scripts/build.sh then
# signs deskdash.app with instead of ad hoc. Optional, and once per Mac.
#
# Why: macOS files privacy permissions (files on an external drive, Accessibility, ...) for an ad-hoc signed app under
# that exact build, so each rebuild asks again, and the service waits on the prompt. Signed with the same identity
# every time, deskdash.app keeps them across rebuilds. The certificate is not trusted for anything and never leaves
# this Mac; only codesign may use its key. --remove deletes it again.
#
# Making it asks for your login password once, in Terminal: macOS keeps a key's users per "partition", and without
# codesign's on the list it asks for the password on every build, even after Always Allow. --allow-codesign does just
# that step, for an identity made before.
set -eu

name="deskdash local signing"
keychain=$HOME/Library/Keychains/login.keychain-db

allow_codesign() {
  echo "Letting codesign use the key without asking. Type your login password (it is not shown):"
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -t private -l "$name" "$keychain" >/dev/null
  echo "Done: builds sign without asking."
}

case ${1:-} in
  --remove)
    security delete-identity -c "$name" "$keychain" && echo "Removed \"$name\"."
    exit 0 ;;
  --allow-codesign)
    allow_codesign
    exit 0 ;;
esac
if security find-certificate -c "$name" "$keychain" >/dev/null 2>&1; then
  echo "\"$name\" is already in your login keychain."
  exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cat > "$work/req.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$work/req.cnf" \
  -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
pass=$(openssl rand -hex 16)
openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -name "$name" \
  -out "$work/id.p12" -passout "pass:$pass"
security import "$work/id.p12" -k "$keychain" -P "$pass" -T /usr/bin/codesign >/dev/null
echo "Added \"$name\" to your login keychain. scripts/build.sh signs with it from now on."
allow_codesign
echo "macOS asks once more for the permissions deskdash had; after that they stay across rebuilds."
