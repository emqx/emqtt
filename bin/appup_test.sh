#!/usr/bin/env bash
set -euo pipefail
BASEDIR=$(dirname $(realpath "$0"))

## @DOC
## The script is used to test the appup.src file with following steps,
## 1) It builds all release tar files of *current* vsn and old vsns that they are defined in ${supported_rel_vsns}
## 2) It untar all the tar files to one tmp dir then build the *relup* file from there. see make_relup()
## 3) It then append the relup file to the tar file of current release, see make_relup()
## 4) It then test the old vsn upgrade and downgrade, see test_relup()

# GLOBAL
app=emqtt
supported_rel_vsns="1.4.6"

die()
{
    echo "$1"
    exit 1;
}

build_and_save_tar() {
    dest_dir="$1"

    if rebar3 plugins list |grep relup_helper; then
        rebar3 as emqtt_relup_test do relup_helper gen_appups,tar;
    else
        rebar3 as emqtt_relup_test do tar
    fi

    mv _build/emqtt_relup_test/rel/emqtt/emqtt-*.tar.gz "${dest_dir}"
}

build_legacy() {
    dest_dir="$1"
    for vsn in ${supported_rel_vsns};
    do
        echo "building rel tar for $vsn"
        vsn_dir="$dest_dir/$app-$vsn"
        # FIXME, this is temp repo for test
        git clone https://github.com/emqx/emqtt.git -b "$vsn" --recursive --depth 1 "$vsn_dir"
        pushd ./
        cd ${vsn_dir}
        build_and_save_tar "$dest_dir";
        popd
    done
}

untar_all_pkgs() {
    local dir="$1/"
    local appdir="$dir/$app"
    mkdir -p "$appdir"
    for f in ${dir}/*.tar.gz;
    do
        tar zxf "$f" -C "$appdir";
    done
}

prepare_releases() {
    local dest_dir="$1"
    build_and_save_tar "$dest_dir"
    build_legacy "$dest_dir"
    untar_all_pkgs "$dest_dir"
}

erl_eval() {
    local node_cmd="$1"
    local cmd="$2"
    local expected_res="$3"
    [ ! -f $node_cmd ] && die "$node_cmd not found"
    res=$($node_cmd eval "$2")
    if [[ $expected_res != $res  ]]; then
       die "Failed: eval: $cmd\n but returns $res"
    fi
}

test_relup() {
    local tar_dir="$1"
    local target_vsn="$2"

    for vsn in ${supported_rel_vsns};
    do
        echo "unpack"
        appdir="${tar_dir}/${vsn}/"
        rm --preserve-root -rf "${appdir}/"
        mkdir -p ${appdir}
        tar zxf "$tar_dir/$app-$vsn.tar.gz" -C "$appdir"

        ##
        ## Start Old Version of EMQTT
        ##
        echo "starting $vsn"
        appscript="${appdir}/bin/emqtt"
        trap "timeout 3 $appscript stop || echo ok" EXIT
        $appscript daemon -- -mode interactive
        $appscript ping
        $appscript versions

        ##
        ## Deploy NEW Target Version
        ##
        echo "deploy $target_vsn"
        cp "$tar_dir/$app-$target_vsn.tar.gz" "$appdir/releases/"
        $appscript versions

        $appscript eval 'spawn(fun() -> process_flag(trap_exit, true), {ok, Pid}=emqtt:start_link(), ets:insert(ac_tab,{{application_master, emqtt}, Pid}), true=register(test_client1, Pid), receive stop -> ok end end).'
        erl_eval "$appscript" 'true = is_process_alive(whereis(test_client1)).' 'true'

        ##
        ## Trigger UPGRADE and check results
        ##
        echo "Upgrade test"
        $appscript upgrade --no-permanent "$target_vsn"
        $appscript ping
        $appscript versions
        erl_eval "$appscript" 'false = erlang:check_process_code(whereis(test_client1),emqtt).' 'false'
        erl_eval "$appscript" 'ok = gen_statem:stop(test_client1).' 'ok'
        echo "Upgrade test done and success"


        $appscript eval 'spawn(fun() -> process_flag(trap_exit, true), {ok, Pid}=emqtt:start_link(), ets:insert(ac_tab,{{application_master, emqtt},Pid}), true=register(test_client1, Pid), receive stop -> ok end end).'
        erl_eval "$appscript" 'true = is_process_alive(whereis(test_client1)).' 'true'

        ##
        ## Trigger DOWNGRADE and check results
        ## note, downgrade isn't supported yet
        echo "Start downgrade test"
        $appscript downgrade "$vsn"
        erl_eval "$appscript" 'false = erlang:check_process_code(whereis(test_client1),emqtt).' 'false'
        erl_eval "$appscript" 'ok = gen_statem:stop(test_client1).' 'ok'
        echo "Downgrade test done and success"

    done;
}

make_relup() {
    local tmpdir="$1"
    local current_vsn="$2"
    local appdir="$1/$app"

    untar_all_pkgs "$tmpdir"
    pushd ./

    cd "${appdir}"
    for vsn in $supported_rel_vsns $current_vsn;
    do
        [ -e "${vsn}.rel" ] || ln -s "releases/$vsn/emqtt.rel" "$vsn.rel"
    done

    ${BASEDIR}/generate_relup.escript "$current_vsn" "${supported_rel_vsns/ /,}" "$PWD" "lib/" "$PWD/releases/${current_vsn}"
    popd

    gzip -d "${tmpdir}/emqtt-${current_vsn}.tar.gz"
    tar rvf "${tmpdir}/emqtt-${current_vsn}.tar"  -C "$appdir" "releases/${current_vsn}/relup"
    gzip "${tmpdir}/emqtt-${current_vsn}.tar"
}

current_vsn() {
    git describe --tags --always
}

main() {
    tmpdir=$(realpath $(mktemp -d -p . --suffix '.relup_test'))
    current_vsn=$(current_vsn)
    echo "Using temp dir: $tmpdir"
    prepare_releases "$tmpdir"
    untar_all_pkgs "$tmpdir"
    make_relup "$tmpdir" "$current_vsn"
    test_relup "$tmpdir" "$current_vsn"
}


cmd=${1:-"main"}

[ $# -gt 0 ] && shift 1
"$cmd" $@
exit 0;
