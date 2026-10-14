#! /bin/bash
#
# Smoke test of installed SmartMet Server release RPMs: smartmetd is started once
# using the configuration from docker-smartmetserver repository (paths relocated
# under the workspace, lazy linking disabled), a few requests are sent to it and
# the server output is checked for missing symbols, crashes and other fatal errors.
#
# In addition to the Docker image configuration, also engines used in FMI production
# servers are enabled: geonames engine with database (smartmet-test-db), grid engine
# (Valkey with grid test configuration) and satellite engine (smartmet-test-data).
#
# Environment:
#   DOCKER_SMARTMETSERVER_REPO  Git repository of the configuration
#   SMOKE_TIMEOUT               max seconds to wait for server startup (default 300)

repo=${DOCKER_SMARTMETSERVER_REPO:-https://github.com/fmidev/docker-smartmetserver.git}
startup_timeout=${SMOKE_TIMEOUT:-300}

# Requests to send: URL path and a string which must be present in the response
REQUESTS="
/wms?service=WMS&version=1.3.0&request=GetCapabilities|WMS_Capabilities
/edr|links
/edr/collections|collections
/timeseries?source=grid&starttime=200808051200&place=Helsinki&timesteps=3&param=name,time,Temperature&format=json|Helsinki
"

top=$(pwd)
work=$top/workspace/smoke-test
dbdir=$work/test-db
griddir=$work/grid-test
logdir=$top/workspace/log/smoke-test
log=$logdir/smartmetd.log
smartmetd=$(command -v smartmetd || echo /usr/sbin/smartmetd)

error_patterns='undefined symbol|cannot open shared object|Segmentation fault|SIGSEGV|SIGABRT|terminate called|AddressSanitizer|core dumped|failure reported'

rm -rf $work $logdir
mkdir -p $work $logdir

echo "Installing packages"
sudo yum install -y \
    smartmet-server \
    smartmet-plugin-autocomplete \
    smartmet-plugin-download \
    smartmet-plugin-edr \
    smartmet-plugin-q3 \
    smartmet-plugin-timeseries \
    smartmet-plugin-wms \
    smartmet-engine-avi \
    smartmet-engine-grid \
    smartmet-engine-observation \
    smartmet-engine-satellite \
    smartmet-engine-sputnik \
    smartmet-library-grid-files-test \
    smartmet-test-data \
    smartmet-test-db \
    valkey \
    lua-newcairo-q3 \
    glibc-langpack-en \
    glibc-langpack-fi || exit 1

echo "Fetching configuration from $repo"
git clone -q --depth 1 $repo $work/docker || exit 1

# Same layout as in the Docker image, but relocated under $work
cp -r $work/docker/smartmetconf $work/etc
mkdir -p $work/smartmet/share $work/log
cp -r $work/docker/wms $work/smartmet/share/wms
mkdir -p $work/smartmet/share/dali $work/var/smartmet/archivecache

grep -rlI -e /etc/smartmet -e '"/smartmet/' -e /var/smartmet -e /var/log/smartmet $work/etc | \
    xargs -r sed -i \
        -e "s|/etc/smartmet|$work/etc|g" \
        -e "s|\"/smartmet/|\"$work/smartmet/|g" \
        -e "s|/var/smartmet|$work/var/smartmet|g" \
        -e "s|/var/log/smartmet|$work/log|g"

# q3 plugin uses its own configuration format and has default cache location under /var/smartmet
sed -i -e "s|^rootdir=.*|rootdir= $work/smartmet/\ncache= $work/var/smartmet/archivecache/.q3_cache|" $work/etc/plugins/q3.conf

# Geonames engine: use the test database
sed -i -e '/^database:/,/^}/{s/^\([[:space:]]*\)disable[[:space:]]*=.*/\1disable  = false;/;s|^\([[:space:]]*\)host[[:space:]]*=.*|\1host     = "'$dbdir'";\n\1port     = 5444;|}' \
    $work/etc/engines/geonames.conf

# Grid engine: use the grid test configuration (content in Valkey, data from smartmet-test-data)
sed -i -e "s|\"engines/grid.conf\"|\"$griddir/grid/engine/grid-engine.conf\"|" $work/etc/smartmet.conf
sed -i -e 's/^\([[:space:]]*gridengine_disabled[[:space:]]*=\).*/\1 false;/' \
    $work/etc/plugins/edr.conf $work/etc/plugins/timeseries.conf

# Satellite engine with satellite images from smartmet-test-data
cat >$work/etc/engines/satellite.conf <<EOF
rootdir = "/usr/share/smartmet/test/data/satellite";
products:
{
        meteosat_natural:
        {
                producer = "meteosat";
                parameter = "natural";
                directory = "seviri/0deg/level3/EPSG3035/img";
                pattern = ".*_EPSG3035_natural_with_colorized_ir_clouds\\\\.tif\$";
                title = "Natural colours with colorized IR clouds";
                max_files = 50;
        };
};
EOF
sed -i -e 's|^engines:.*|&\n{\n\tsatellite:\n\t{\n\t\tconfigfile = "engines/satellite.conf";\n\t};|' \
    -e '/^engines:/{n;/^{$/d}' $work/etc/smartmet.conf

# Detect missing symbols in plugins already when loading them
sed -i -e 's/^[[:space:]]*lazylinking[[:space:]]*=.*/lazylinking = false;/' $work/etc/smartmet.conf

# Data and cache directories referenced by the configuration
grep -rhoE "\"$work/(smartmet/data|var/smartmet/cache)/[^\"]*\"" $work/etc | tr -d '"' | sort -u | xargs -r mkdir -p

port=$(sed -n -e 's/^[[:space:]]*port[[:space:]]*=[[:space:]]*\([0-9]*\).*/\1/p' $work/etc/smartmet.conf | head -n 1)
port=${port:-8080}

cleanup() {
    test -f $griddir/grid/redis/redis-server.pid && kill $(cat $griddir/grid/redis/redis-server.pid)
    /usr/share/smartmet/test/db/test-db-ctl.sh $dbdir stop -w >/dev/null
}
trap cleanup EXIT

echo "Creating and starting geonames test database"
if ! /usr/share/smartmet/test/db/create-local-db.sh $dbdir >$logdir/test-db-create.log 2>&1 ; then
    tail -n 50 $logdir/test-db-create.log
    exit 1
fi
/usr/share/smartmet/test/db/test-db-ctl.sh $dbdir start -w || exit 1

echo "Starting Valkey for grid engine"
mkdir -p $griddir
cp -pr /usr/share/smartmet/test/grid $griddir/
cat >$griddir/environment.conf <<EOF
REDIS_CONTENT_SERVER_ADDRESS        = "127.0.0.1"
REDIS_CONTENT_SERVER_PORT           = 6380
REDIS_CONTENT_SERVER_TABLE_PREFIX   = "test."
REDIS_CONTENT_SERVER_DATA_DIR       = "%(DIR)/grid/redis"
EOF
smartmet-grid-test-config-creator $griddir/environment.conf $griddir/grid/redis/redis-template.conf $griddir/grid/redis/redis.conf || exit 1
valkey-server $griddir/grid/redis/redis.conf || exit 1

echo "Starting $smartmetd"
cd $work/etc
timeout --signal=KILL $((startup_timeout + 600)) $smartmetd -v -c $work/etc/smartmet.conf >$log 2>&1 &
pid=$!
cd $top

ok=true
t=0
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
    echo "Server started in $t seconds"
    n=0
    while IFS='|' read url expect ; do
        [ -z "$url" ] && continue
        n=$((n + 1))
        out=$logdir/response-$n.out
        status=$(curl -g -s -o $out -w '%{http_code}' --max-time 120 "http://127.0.0.1:$port$url")
        echo "  $url: HTTP $status"
        if [ "$status" != "200" ] ; then
            ok=false
            head -c 2000 $out ; echo
        elif ! grep -q "$expect" $out ; then
            echo "  Response does not contain '$expect'"
            ok=false
            head -c 2000 $out ; echo
        fi
        if ! kill -0 $pid 2>/dev/null ; then
            echo "Server died while processing $url"
            ok=false
            break
        fi
    done <<<"$REQUESTS"
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
ret=$?
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
    echo "---- Last lines of server output ----"
    tail -n 100 $log
    echo "----"
    echo "Smoke test failed"
    exit 1
fi
echo "Smoke test passed"
