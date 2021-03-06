{ stdenv, lib, fetchurl, fetchpatch, makeWrapper, autoreconfHook
, pkgconfig, which
, flex, bison
, linuxHeaders ? stdenv.cc.libc.linuxHeaders
, gawk
, withPerl ? stdenv.hostPlatform == stdenv.buildPlatform && lib.any (lib.meta.platformMatch stdenv.hostPlatform) perl.meta.platforms, perl
, withPython ? stdenv.hostPlatform == stdenv.buildPlatform && lib.any (lib.meta.platformMatch stdenv.hostPlatform) python.meta.platforms, python
, swig
, ncurses
, pam
, libnotify
, buildPackages
, coreutils
, gnugrep
, gnused
, kmod
, writeShellScript
, closureInfo
, runCommand
}:

let
  apparmor-series = "3.0";
  apparmor-patchver = "0";
  apparmor-version = apparmor-series + "." + apparmor-patchver;

  apparmor-meta = component: with stdenv.lib; {
    homepage = "https://apparmor.net/";
    description = "A mandatory access control system - ${component}";
    license = licenses.gpl2;
    maintainers = with maintainers; [ phreedom thoughtpolice joachifm ];
    platforms = platforms.linux;
  };

  apparmor-sources = fetchurl {
    url = "https://launchpad.net/apparmor/${apparmor-series}/${apparmor-series}/+download/apparmor-${apparmor-version}.tar.gz";
    sha256 = "0pkm8f619c0ra8kpjmarzl9d409dn4sy0kl6mb92gd0ywlgpbzb6";
  };

  aa-teardown = writeShellScript "aa-teardown" ''
    PATH="${lib.makeBinPath [coreutils gnused gnugrep]}:$PATH"
    . ${apparmor-parser}/lib/apparmor/rc.apparmor.functions
    remove_profiles
  '';

  prePatchCommon = ''
    chmod a+x ./common/list_capabilities.sh ./common/list_af_names.sh
    patchShebangs ./common/list_capabilities.sh ./common/list_af_names.sh
    substituteInPlace ./common/Make.rules --replace "/usr/bin/pod2man" "${buildPackages.perl}/bin/pod2man"
    substituteInPlace ./common/Make.rules --replace "/usr/bin/pod2html" "${buildPackages.perl}/bin/pod2html"
    substituteInPlace ./common/Make.rules --replace "/usr/include/linux/capability.h" "${linuxHeaders}/include/linux/capability.h"
    substituteInPlace ./common/Make.rules --replace "/usr/share/man" "share/man"
  '';

  patches = [
    ./fix-build-failure-in-apparmor.patch
  ] ++ stdenv.lib.optionals stdenv.hostPlatform.isMusl [
    (fetchpatch {
      url = "https://git.alpinelinux.org/aports/plain/testing/apparmor/0003-Added-missing-typedef-definitions-on-parser.patch?id=74b8427cc21f04e32030d047ae92caa618105b53";
      name = "0003-Added-missing-typedef-definitions-on-parser.patch";
      sha256 = "0yyaqz8jlmn1bm37arggprqz0njb4lhjni2d9c8qfqj0kll0bam0";
    })
  ];

  # Set to `true` after the next FIXME gets fixed or this gets some
  # common derivation infra. Too much copy-paste to fix one by one.
  doCheck = false;

  # FIXME: convert these to a single multiple-outputs package?

  libapparmor = stdenv.mkDerivation {
    name = "libapparmor-${apparmor-version}";
    src = apparmor-sources;

    nativeBuildInputs = [
      autoreconfHook
      bison
      flex
      pkgconfig
      swig
      ncurses
      which
      perl
    ];

    buildInputs = []
      ++ stdenv.lib.optional withPerl perl
      ++ stdenv.lib.optional withPython python;

    # required to build apparmor-parser
    dontDisableStatic = true;

    prePatch = prePatchCommon + ''
      substituteInPlace ./libraries/libapparmor/swig/perl/Makefile.am --replace install_vendor install_site
      substituteInPlace ./libraries/libapparmor/swig/perl/Makefile.in --replace install_vendor install_site
      substituteInPlace ./libraries/libapparmor/src/Makefile.am --replace "/usr/include/netinet/in.h" "${stdenv.lib.getDev stdenv.cc.libc}/include/netinet/in.h"
      substituteInPlace ./libraries/libapparmor/src/Makefile.in --replace "/usr/include/netinet/in.h" "${stdenv.lib.getDev stdenv.cc.libc}/include/netinet/in.h"
    '';
    inherit patches;

    postPatch = "cd ./libraries/libapparmor";
    # https://gitlab.com/apparmor/apparmor/issues/1
    configureFlags = [
      (stdenv.lib.withFeature withPerl "perl")
      (stdenv.lib.withFeature withPython "python")
    ];

    outputs = [ "out" ] ++ stdenv.lib.optional withPython "python";

    postInstall = stdenv.lib.optionalString withPython ''
      mkdir -p $python/lib
      mv $out/lib/python* $python/lib/
    '';

    inherit doCheck;

    meta = apparmor-meta "library";
  };

  apparmor-utils = stdenv.mkDerivation {
    name = "apparmor-utils-${apparmor-version}";
    src = apparmor-sources;

    nativeBuildInputs = [ makeWrapper which ];

    buildInputs = [
      perl
      python
      libapparmor
      libapparmor.python
    ];

    prePatch = prePatchCommon +
      # Do not build vim file
      stdenv.lib.optionalString stdenv.hostPlatform.isMusl ''
        sed -i ./utils/Makefile -e "/\<vim\>/d"
      '' + ''
      substituteInPlace ./utils/apparmor/easyprof.py --replace "/sbin/apparmor_parser" "${apparmor-parser}/bin/apparmor_parser"
      substituteInPlace ./utils/apparmor/aa.py --replace "/sbin/apparmor_parser" "${apparmor-parser}/bin/apparmor_parser"
      substituteInPlace ./utils/logprof.conf --replace "/sbin/apparmor_parser" "${apparmor-parser}/bin/apparmor_parser"
    '';
    inherit patches;
    postPatch = "cd ./utils";
    makeFlags = [ "LANGS=" ];
    installFlags = [ "DESTDIR=$(out)" "BINDIR=$(out)/bin" "VIM_INSTALL_PATH=$(out)/share" "PYPREFIX=" ];

    postInstall = ''
      sed -i $out/bin/aa-unconfined -e "/my_env\['PATH'\]/d"
      for prog in aa-audit aa-autodep aa-cleanprof aa-complain aa-disable aa-enforce aa-genprof aa-logprof aa-mergeprof aa-unconfined ; do
        wrapProgram $out/bin/$prog --prefix PYTHONPATH : "$out/lib/${python.libPrefix}/site-packages:$PYTHONPATH"
      done

      substituteInPlace $out/bin/aa-notify --replace /usr/bin/notify-send ${libnotify}/bin/notify-send
      # aa-notify checks its name and does not work named ".aa-notify-wrapped"
      mv $out/bin/aa-notify $out/bin/aa-notify-wrapped
      makeWrapper ${perl}/bin/perl $out/bin/aa-notify --set PERL5LIB ${libapparmor}/${perl.libPrefix} --add-flags $out/bin/aa-notify-wrapped

      substituteInPlace $out/bin/aa-remove-unknown \
       --replace "/lib/apparmor/rc.apparmor.functions" "${apparmor-parser}/lib/apparmor/rc.apparmor.functions"
      wrapProgram $out/bin/aa-remove-unknown \
       --prefix PATH : ${lib.makeBinPath [gawk]}

      ln -s ${aa-teardown} $out/bin/aa-teardown
    '';

    inherit doCheck;

    meta = apparmor-meta "user-land utilities" // {
      broken = !(withPython && withPerl);
    };
  };

  apparmor-bin-utils = stdenv.mkDerivation {
    name = "apparmor-bin-utils-${apparmor-version}";
    src = apparmor-sources;

    nativeBuildInputs = [
      pkgconfig
      libapparmor
      gawk
      which
    ];

    buildInputs = [
      libapparmor
    ];

    prePatch = prePatchCommon;
    postPatch = "cd ./binutils";
    makeFlags = [ "LANGS=" "USE_SYSTEM=1" ];
    installFlags = [ "DESTDIR=$(out)" "BINDIR=$(out)/bin" "SBINDIR=$(out)/bin" ];

    inherit doCheck;

    meta = apparmor-meta "binary user-land utilities";
  };

  apparmor-parser = stdenv.mkDerivation {
    name = "apparmor-parser-${apparmor-version}";
    src = apparmor-sources;

    nativeBuildInputs = [ bison flex which ];

    buildInputs = [ libapparmor ];

    prePatch = prePatchCommon + ''
      substituteInPlace ./parser/Makefile --replace "/usr/bin/bison" "${bison}/bin/bison"
      substituteInPlace ./parser/Makefile --replace "/usr/bin/flex" "${flex}/bin/flex"
      substituteInPlace ./parser/Makefile --replace "/usr/include/linux/capability.h" "${linuxHeaders}/include/linux/capability.h"
      ## techdoc.pdf still doesn't build ...
      substituteInPlace ./parser/Makefile --replace "manpages htmlmanpages pdf" "manpages htmlmanpages"
      substituteInPlace parser/rc.apparmor.functions \
       --replace "/sbin/apparmor_parser" "$out/bin/apparmor_parser"
      sed -i parser/rc.apparmor.functions -e '2i . ${./fix-rc.apparmor.functions.sh}'
    '';
    inherit patches;
    postPatch = "cd ./parser";
    makeFlags = [
      "LANGS=" "USE_SYSTEM=1" "INCLUDEDIR=${libapparmor}/include"
      "AR=${stdenv.cc.bintools.targetPrefix}ar"
    ];
    installFlags = [ "DESTDIR=$(out)" "DISTRO=unknown" ];

    inherit doCheck;

    meta = apparmor-meta "rule parser";
  };

  apparmor-pam = stdenv.mkDerivation {
    name = "apparmor-pam-${apparmor-version}";
    src = apparmor-sources;

    nativeBuildInputs = [ pkgconfig which ];

    buildInputs = [ libapparmor pam ];

    postPatch = "cd ./changehat/pam_apparmor";
    makeFlags = [ "USE_SYSTEM=1" ];
    installFlags = [ "DESTDIR=$(out)" ];

    inherit doCheck;

    meta = apparmor-meta "PAM service";
  };

  apparmor-profiles = stdenv.mkDerivation {
    name = "apparmor-profiles-${apparmor-version}";
    src = apparmor-sources;

    nativeBuildInputs = [ which ];

    postPatch = "cd ./profiles";
    installFlags = [ "DESTDIR=$(out)" "EXTRAS_DEST=$(out)/share/apparmor/extra-profiles" ];

    inherit doCheck;

    meta = apparmor-meta "profiles";
  };

  apparmor-kernel-patches = stdenv.mkDerivation {
    name = "apparmor-kernel-patches-${apparmor-version}";
    src = apparmor-sources;

    phases = ''unpackPhase installPhase'';

    installPhase = ''
      mkdir "$out"
      cp -R ./kernel-patches/* "$out"
    '';

    inherit doCheck;

    meta = apparmor-meta "kernel patches";
  };

  # Generate generic AppArmor rules in a file,
  # from the closure of given rootPaths.
  # To be included in an AppArmor profile like so:
  # include "$(apparmorRulesFromClosure {} [pkgs.hello]}"
  apparmorRulesFromClosure =
    { # The store path of the derivation is given in $path
      additionalRules ? []
      # TODO: factorize here some other common paths
      # that may emerge from use cases.
    , baseRules ? [
        "r $path"
        "r $path/etc/**"
        "r $path/share/**"
        # Note that not all libraries are prefixed with "lib",
        # eg. glibc-2.30/lib/ld-2.30.so
        "mr $path/lib/**.so*"
        # eg. glibc-2.30/lib/gconv/gconv-modules
        "r $path/lib/**"
      ]
    , name ? ""
    }: rootPaths: runCommand
      ( "apparmor-closure-rules"
      + stdenv.lib.optionalString (name != "") "-${name}") {} ''
    touch $out
    while read -r path
    do printf >>$out "%s,\n" ${lib.concatMapStringsSep " " (x: "\"${x}\"") (baseRules ++ additionalRules)}
    done <${closureInfo {inherit rootPaths;}}/store-paths
  '';
in
{
  inherit
    libapparmor
    apparmor-utils
    apparmor-bin-utils
    apparmor-parser
    apparmor-pam
    apparmor-profiles
    apparmor-kernel-patches
    apparmorRulesFromClosure;
}
