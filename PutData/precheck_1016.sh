#!/usr/bin/env bash
# precheck_1016.sh — 1.0.16 重新啟動前的唯讀考察（客戶 Atlas，MongoDB 9.0.1）。
# 用法: 在 1.0.16 目錄下  sudo bash precheck_1016.sh   （只讀，不寫任何資料）
# 輸出全部脫敏：不印連線字串、不印資料內容、只印 metadata。
set -u
CONF="${1:-nimo-shake.conf}"
[ -f "$CONF" ] || { echo "[FAIL] 找不到 $CONF"; exit 1; }
MURI=$(sed -n 's/^target\.address *= *//p' "$CONF" | tr -d '[:space:]')
ID=$(sed -n 's/^id *= *//p' "$CONF" | tr -d '[:space:]')
CKDB=$(sed -n 's/^checkpoint\.db *= *//p' "$CONF" | tr -d '[:space:]'); [ -n "$CKDB" ] || CKDB="${ID}-checkpoint"
echo "== 0. 程序必須已停（要是 0）"; (pgrep -af "nimo-shake.linux" 2>/dev/null || true) | wc -l
M() { mongosh "$MURI" --quiet --eval "$1" 2>&1 | grep -v "mongodb+srv\|mongodb://"; }

echo; echo "== A. 伺服器身分與 topology"
M 'const b=db.adminCommand({buildInfo:1}), h=db.adminCommand({hello:1});
printjson({version:b.version, setName:h.setName, msg:h.msg, isWritablePrimary:h.isWritablePrimary, maxWireVersion:h.maxWireVersion});
for (const q of [{getParameter:1,featureCompatibilityVersion:1},{getDefaultRWConcern:1},{getParameter:1,writeConcernMajorityJournalDefault:1}]) {
  try { const r=db.adminCommand(q); delete r["$clusterTime"]; delete r.operationTime; printjson(r); }
  catch(e) { printjson({query:Object.keys(q)[0], code:e.code, codeName:e.codeName}); } }'

echo; echo "== B/D. manifest 與逐表狀態（以 manifest 的 23 表為準）"
M "const c=db.getSiblingDB('$CKDB'), d=db.getSiblingDB('$ID');
const m=c.nsr_manifest.findOne({_id:'active'});
if(!m){ print('STOP: active manifest missing'); quit(0); }
printjson({runId:m.runId, state:m.state, schemaVersion:m.schemaVersion, spoolSchemaVersion:m.spoolSchemaVersion,
  blocked:m.blocked?{code:m.blocked.code,resumeState:m.blocked.resumeState,stage:m.blocked.stage,table:m.blocked.table}:null,
  bootstrapReady:m.bootstrapReady, barrierCommitted:m.barrierCommitted, tables:m.tables.length});
const b64=x=>x?EJSON.serialize(x)['\$binary'].base64:null;
for(const n of m.tables){
  const t=c.nsr_tables.findOne({runId:m.runId,table:n});
  const a=d.getCollectionInfos({name:n})[0];
  const u=a&&a.info&&a.info.uuid;
  const exp=t&&(t.preparePhase==='PLANNED'?t.originalUUID:t.targetUUID);
  print(n, '| ckpt='+(t?t.state+'/'+t.preparePhase:'none'), '| type='+(a?a.type:'missing'), '| options='+JSON.stringify(a?a.options:null),
        '| uuidMatch='+(exp&&u?(b64(exp)===b64(u)):'n/a'), '| est='+(a?d[n].estimatedDocumentCount():'-'));
}
printjson({segments:c.nsr_segments.countDocuments({runId:m.runId}), shards:c.nsr_shards.countDocuments({runId:m.runId}), spool:c.nsr_spool.countDocuments({runId:m.runId})});"

echo; echo "== B2. 第一張表是否真的空（majority read）"
M "const r=db.getSiblingDB('$ID').runCommand({find:'cmn_activity_m',filter:{},projection:{_id:1},limit:1,singleBatch:true,readConcern:{level:'majority'},maxTimeMS:10000});
printjson({ok:r.ok, empty:r.ok===1?r.cursor.firstBatch.length===0:null, code:r.code, codeName:r.codeName});"

echo; echo "== C. 索引：目的端 23 表 + checkpoint 5 個 collection"
M "const c=db.getSiblingDB('$CKDB'), d=db.getSiblingDB('$ID');
const m=c.nsr_manifest.findOne({_id:'active'}); if(!m){ quit(0); }
for(const n of m.tables){ const a=d.getCollectionInfos({name:n})[0];
  print('## '+n+(a?'':' (missing)')); if(a&&a.type==='collection') print(EJSON.stringify(d[n].getIndexes(),{relaxed:false})); }
const have=c.getCollectionNames(); for(const n of ['nsr_manifest','nsr_tables','nsr_segments','nsr_shards','nsr_spool']){ print('## ckpt.'+n+(have.includes(n)?'':' (not yet created — normal before capture bootstrap)')); if(have.includes(n)) print(EJSON.stringify(c[n].getIndexes(),{relaxed:false})); }"

echo; echo "== P. 帳號權限（只印角色與 privilege 動作）"
M "const r=db.adminCommand({connectionStatus:1,showPrivileges:true});
if(r.ok!==1){ printjson({code:r.code}); quit(0); }
printjson(r.authInfo.authenticatedUserRoles);
const acts={}; (r.authInfo.authenticatedUserPrivileges||[]).forEach(p=>{const k=JSON.stringify(p.resource); acts[k]=(acts[k]||[]).concat(p.actions);});
Object.keys(acts).forEach(k=>print(k, Array.from(new Set(acts[k])).sort().join(',')));"

echo; echo "== E. 來源端（有 aws CLI 才跑）"
if command -v aws >/dev/null 2>&1; then
  REGION=$(sed -n 's/^source\.region *= *//p' "$CONF" | tr -d '[:space:]')
  export AWS_ACCESS_KEY_ID=$(sed -n 's/^source\.access_key_id *= *//p' "$CONF" | tr -d '[:space:]')
  export AWS_SECRET_ACCESS_KEY=$(sed -n 's/^source\.secret_access_key *= *//p' "$CONF" | tr -d '[:space:]')
  aws sts get-caller-identity --query Account --output text --no-cli-pager 2>&1 | sed 's/[0-9]\{6\}$/******/'
  TABLES=$(M "const m=db.getSiblingDB('$CKDB').nsr_manifest.findOne({_id:'active'}); if(m) print(m.tables.join('\n'));")
  while IFS= read -r T; do [ -n "$T" ] || continue
    aws dynamodb describe-table --table-name "$T" --region "$REGION" --no-cli-pager --output text \
      --query 'Table.[TableName,TableStatus,StreamSpecification.StreamViewType,LatestStreamArn,CreationDateTime]' 2>&1 | sed 's/[0-9]\{12\}:table/************:table/'
  done <<< "$TABLES"
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
else
  echo "(no aws CLI; skipped — 程式啟動時會自行檢查 stream)"
fi
unset MURI
echo; echo "== done"
