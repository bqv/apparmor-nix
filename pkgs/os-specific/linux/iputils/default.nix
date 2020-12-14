{ stdenv, fetchFromGitHub, fetchpatch
, meson, ninja, pkgconfig, gettext, libxslt, docbook_xsl_ns
, libcap, libidn2
, apparmorRulesFromClosure
}:

with stdenv.lib;

let
  version = "20200821";
  sunAsIsLicense = {
    fullName = "AS-IS, SUN MICROSYSTEMS license";
    url = "https://github.com/iputils/iputils/blob/s${version}/rdisc.c";
  };
in stdenv.mkDerivation rec {
  pname = "iputils";
  inherit version;

  src = fetchFromGitHub {
    owner = pname;
    repo = pname;
    rev = "s${version}";
    sha256 = "1jhbcz75a4ij1myyyi110ma1d8d5hpm3scz9pyw7js6qym50xvh4";
  };

  patches = [
    # Proposed upstream patch to reduce dependency on systemd: https://github.com/iputils/iputils/pull/297
    (fetchpatch {
      url = "https://github.com/iputils/iputils/commit/13d6aefd57fd471ecad06e19073dcc44608dff5e.patch";
      sha256 = "1n62zxmzp7hgz9qapbbpqv3fxqvc3qyd2a73jhp357x6by84kj49";
    })
  ];

  outputs = ["out" "apparmor"];

  mesonFlags = [
    "-DBUILD_RARPD=true"
    "-DBUILD_TRACEROUTE6=true"
    "-DBUILD_TFTPD=true"
    "-DNO_SETCAP_OR_SUID=true"
    "-Dsystemdunitdir=etc/systemd/system"
    "-DINSTALL_SYSTEMD_UNITS=true"
  ]
    # Disable idn usage w/musl (https://github.com/iputils/iputils/pull/111):
    ++ optional stdenv.hostPlatform.isMusl "-DUSE_IDN=false";

  nativeBuildInputs = [ meson ninja pkgconfig gettext libxslt.bin docbook_xsl_ns ];
  buildInputs = [ libcap ]
    ++ optional (!stdenv.hostPlatform.isMusl) libidn2;
  postInstall = ''
    install -D /dev/stdin $apparmor/bin.ping <<EOF
    include <tunables/global>
    $out/bin/ping {
      include <abstractions/base>
      include <abstractions/consoles>
      include <abstractions/nameservice>
      include "${apparmorRulesFromClosure { name = "ping"; }
       ([libcap] ++ optional (!stdenv.hostPlatform.isMusl) libidn2)}"
      include <local/bin.ping>
      capability net_raw,
      network inet raw,
      network inet6 raw,
      mr $out/bin/ping,
      r $out/share/locale/**,
      r @{PROC}/@{pid}/environ,
    }
    EOF
  '';

  meta = {
    description = "A set of small useful utilities for Linux networking";
    inherit (src.meta) homepage;
    changelog = "https://github.com/iputils/iputils/releases/tag/s${version}";
    license = with licenses; [ gpl2Plus bsd3 sunAsIsLicense ];
    platforms = platforms.linux;
    maintainers = with maintainers; [ primeos lheckemann ];

    longDescription = ''
      A set of small useful utilities for Linux networking including:

      arping
      clockdiff
      ninfod
      ping
      rarpd
      rdisc
      tftpd
      tracepath
      traceroute6
    '';
  };
}
