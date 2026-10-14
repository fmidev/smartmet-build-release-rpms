#! /bin/bash
#
# Smoke test of installed SmartMet Server release RPMs: smartmetd is started
# separately for each plugin using the reactor configuration from the plugin's
# own tests (but with the installed plugin and engines), a few requests from the
# plugin's test inputs are sent to it and the server output is checked for missing
# symbols, crashes and other fatal errors.
#
# Usage: smoke-test.sh [plugin ...]   (default: all plugins listed below)
#
# Environment:
#   SMOKE_REQUESTS   number of requests to send per plugin (default 2)
#   SMOKE_TIMEOUT    max seconds to wait for server startup (default 300)

# plugin : test directory : reactor config (relative to test directory)
PLUGINS="
autocomplete:test:cnf/reactor.conf
avi:test:cnf/reactor.conf
edr:test/base:cnf/reactor.conf
q3:test:cnf/reactor.conf
textgen:test:cnf/reactor.conf
timeseries:test/base:cnf/reactor_testdb.conf
trajectory:test:cnf/reactor.conf
"

nrequests=${SMOKE_REQUESTS:-2}
startup_timeout=${SMOKE_TIMEOUT:-300}

top=$(pwd)
mirror=$top/workspace/mirror
work=$top/workspace/smoke-test
logdir=$top/workspace/log/smoke-test
dbdir=$work/test-db
smartmetd=$(command -v smartmetd || echo /usr/sbin/smartmetd)

error_patterns='undefined symbol|cannot open shared object|Segmentation fault|SIGSEGV|SIGABRT|terminate called|AddressSanitizer|core dumped'

rm -rf $work $logdir
mkdir -p $work $logdir

if [ $# -gt 0 ] ; then
    selected=$*
else
    selected=$(echo "$PLUGINS" | cut -d: -f1)
fi

echo "Installing test data, test database and plugins"
pkgs="smartmet-server smartmet-test-data smartmet-test-db"
for p in $selected ; do pkgs="$pkgs smartmet-plugin-$p" ; done
sudo yum install -y $pkgs || exit 1

echo "Creating and starting test database"
if ! /usr/share/smartmet/test/db/create-local-db.sh $dbdir >$logdir/test-db-create.log 2>&1 ; then
    cat $logdir/test-db-create.log
    exit 1
fi
/usr/share/smartmet/test/db/test-db-ctl.sh $dbdir start -w || exit 1
trap "/usr/share/smartmet/test/db/test-db-ctl.sh $dbdir stop -w" EXIT

# Runs smartmetd for one plugin. Returns non-zero on failure.
run_plugin_test() {
    local name=$1 testdir=$2 reactor=$3 port=$4
    local repo=$mirror/smartmet-plugin-$name.git
    local src=$work/$name
    local log=$logdir/$name.log

    if [ ! -d $repo ] ; then
        echo "No mirror $repo"
        return 1
    fi

    # Take test configuration from plugin's Git repository (tmpl is needed by some configurations)
    mkdir -p $src
    local dirs=test
    if git --git-dir=$repo cat-file -e HEAD:tmpl 2>/dev/null ; then dirs="$dirs tmpl" ; fi
    git --git-dir=$repo archive HEAD $dirs | tar -x -C $src || return 1

    # Same edits as done by plugin test Makefiles in CI
    find $src/test -name '*.conf.in' | while read f ; do
        sed -e "s|\"smartmet-test\"|\"$dbdir\"|g" \
            -e "s|\"@IOT_OBS@\"|\"$dbdir\"|g" \
            -e "s|@DB_TYPE@|sqlite|g" \
            $f >${f%.in}
    done

    local cnf=$src/$testdir/$reactor
    if [ ! -f $cnf ] ; then
        echo "Reactor configuration $cnf not found"
        return 1
    fi
    # Use installed plugin instead of one from the build directory
    sed -i -e '/^[[:space:]]*libfile[[:space:]]*=/d' $cnf

    cd $(dirname $cnf)
    timeout --signal=KILL $((startup_timeout + 600)) \
        $smartmetd -v -p $port -c $cnf >$log 2>&1 &
    local pid=$!
    cd $top

    local ok=true
    local t=0
    until grep -q "Launched.*server" $log ; do
        if ! kill -0 $pid 2>/dev/null ; then
            echo "Server exited during startup"
            ok=false
            break
        fi
        if [ $t -ge $startup_timeout ] ; then
            echo "Server did not start in $startup_timeout seconds"
            ok=false
            break
        fi
        sleep 1
        t=$((t + 1))
    done

    if $ok ; then
        for input in $(ls $src/$testdir/input/*.get 2>/dev/null | sort | head -n $nrequests) ; do
            local url=$(head -n 1 $input | awk '{print $2}')
            local status=$(curl -g -s -o /dev/null -w '%{http_code}' --max-time 120 "http://127.0.0.1:$port$url")
            echo "  $(basename $input): HTTP $status"
            if [ "$status" = "000" ] ; then ok=false ; fi
            if ! kill -0 $pid 2>/dev/null ; then
                echo "Server died while processing $(basename $input)"
                ok=false
                break
            fi
        done
    fi

    if kill -0 $pid 2>/dev/null ; then
        kill -TERM $pid
        t=0
        while kill -0 $pid 2>/dev/null && [ $t -lt 60 ] ; do sleep 1 ; t=$((t + 1)) ; done
        if kill -0 $pid 2>/dev/null ; then
            echo "Server did not stop in 60 seconds"
            kill -KILL $pid
            ok=false
        fi
    fi
    wait $pid
    local ret=$?
    # 143 = terminated by SIGTERM
    if [ $ret -ne 0 ] && [ $ret -ne 143 ] ; then
        echo "Server exited with status $ret"
        ok=false
    fi

    if grep -E -q "$error_patterns" $log ; then
        echo "Errors found in server output:"
        grep -E "$error_patterns" $log | head -20
        ok=false
    fi

    if ! $ok ; then
        echo "---- Last lines of $name server output ----"
        tail -n 50 $log
        echo "----"
    fi
    $ok
}

failed=
port=18080
for p in $selected ; do
    line=$(echo "$PLUGINS" | grep "^$p:")
    if [ -z "$line" ] ; then
        echo "Unknown plugin $p"
        failed="$failed $p"
        continue
    fi
    IFS=: read name testdir reactor <<<"$line"
    echo "==== Testing plugin $name"
    if run_plugin_test $name $testdir $reactor $port ; then
        echo "==== $name: OK"
    else
        echo "==== $name: FAILED"
        failed="$failed $name"
    fi
    port=$((port + 1))
done

if [ -n "$failed" ] ; then
    echo "Smoke test failed for:$failed"
    exit 1
fi
echo "Smoke test passed"
