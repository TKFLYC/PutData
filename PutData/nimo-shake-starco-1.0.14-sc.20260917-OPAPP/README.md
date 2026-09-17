# nimo-shake-starco 1.0.14-sc.20260917-OPAPP

DynamoDB → MongoDB 搬遷 + 逐欄位型別校驗工具包(基於 Alibaba NimoShake 1.0.14,含 StarCo 改寫:
`mchange_cast` 寫入前型別轉換 + nimo-full-check 校驗引擎),**OPAPP 型別轉換專版**。

本版規則檔為 v2 格式(以「表 + 頂層欄位」為作用域),管理 **23 張表 / 43 個受治理欄位**
(33 個 Int32、10 個 Int64);規則檔為 `type_rules_opapp.json`,搬遷與校驗兩工具共用同一份。

## 三行上手

```bash
vi nimo-shake.conf type_rules_opapp.json      # conf 填 id(=目標 db 名)/ AWS 金鑰 / region / MongoDB 連線字串;規則檔 scope.database 改成同一個 db 名
./nimo-shake.linux -conf ./nimo-shake.conf    # 啟動搬遷(前景執行,畫面直接看進度)
# 出廠 sync_mode=all:等 "full sync done!" 出現即全量完成,接著轉入增量、程式不會自行退出(只要全量請改 sync_mode=full,會印 "sync complete!" 後退出)
```

⚠️ 出廠的 `nimo-shake.conf` 的 `id`(`REPLACE_WITH_TARGET_DATABASE_ID`)與 `type_rules_opapp.json` 的 `scope.database`(`REPLACE_WITH_SAME_TARGET_DATABASE_ID`)**都是佔位值,而且刻意不相同**。
兩者必須改成同一個實際的目標資料庫名;沒改、或改得不一致,程式**啟動即失敗、目的端零異動**(這是刻意的防呆,不是故障)。

全量 + 增量(`sync_mode = all`,出廠值)不會自行退出;只做全量(`sync_mode = full`)跑完程式會自行退出。詳細 log 在 `nimo-shake.log`。
需要背景執行(登出不中斷)、或想要啟動防呆(檔案檢查/重複啟動偵測/啟動失敗回報)時,可改用附帶的啟停腳本:

```bash
./start.sh                # 背景啟動(setsid;預設吃 nimo-shake.conf)+ preflight 檢查
./stop.sh                 # 停止(跑完後再執行只是確認,不會報錯)
```

啟動後 log 開頭必須看到**啟動摘要三行**(每個程序只印一次):

```text
schema=v2 semantics=collection_scoped config_id=opapp.type-conversion config_version=2026-09-11.1 database=<conf 的 id> collections=23 governed_collections=20 preserve_only=3 rules=43 rules_sha256=<規則檔 SHA256>
source _id fields=0; convert._id has no effect
source_id_basis=declared_mapping convert_id=pre
```

`collections=23 governed_collections=20 preserve_only=3 rules=43` 字面必須完全相同;`rules_sha256` 必須等於現場 `sha256sum type_rules_opapp.json`(填完 `scope.database` 之後的檔案),且與校驗工具 `rule-coverage.json` 的 `rules_sha256`、checkpoint 指紋三者一致。`SHA256SUMS` 驗的是出廠檔,填值後規則檔的 hash 必然改變。

搬遷完成後校驗(逐欄位型別驗證,全量,23 張表白名單須列全):

```bash
./nimo-full-check.linux \
  -s <ACCESS_KEY> --sourceSecretAccessKey=<SECRET_KEY> --sourceRegion=<region> \
  -t "mongodb+srv://<帳號>:<密碼>@<cluster>/" -i <目標db名> \
  -c mchange_cast --convertTypeRulesPath=type_rules_opapp.json --convertId=pre \
  -m dynamodb --sample=0 \
  --filterCollectionWhite="cmn_activity_m;cmn_coupon_m;ec_qrcode_benefits_code;ec_qrcode_benefits_codemapping;ec_qrcode_benefits_main;egtc_traded_m;event_record_main;event_record_traded_m;external_import_traded_m;imm_traded_m;inapp_notice_m;inside_link_m;itc_coupon_m;member_benefits_m;mms_coupon_m;mms_event_record;my_notice_m;pos_activity_m;pos_coupon_m;s_feature;s_vender_business_config;user_account_m;user_def_payment" \
  -d out_check
echo "exit=$?"
```

| exit | outcome | 意義 |
|---|---|---|
| 0 | `PASS` | 全數通過,且規則覆蓋完整 → 全綠 |
| 1 | `FAIL` | 存在轉型錯誤 / 兩端不一致(`failed > 0` 或 `target_only > 0`)|
| 2 | `EXECUTION_ERROR` | 執行障礙(連線/權限/參數),**或校驗沒跑完、或規則覆蓋不完整**(有規則從未命中資料);此時 `checked` 數字不可拿來對帳 |
| 3 | `PASS_WITH_EXCEPTIONS` | 通過但來源有不可轉資料(`SOURCE_UNCASTABLE`);**不是全綠**,每筆例外須逐案判定後才能結案 |

詳細部署、參數、增量、續跑前檢核、報告判讀:見 `docs/部署與使用說明.md`;實測結果見 `docs/驗證報告_2026-09-17.md`。

## 檔案清單

| 檔案 | 說明 |
|---|---|
| nimo-shake.linux | 搬遷工具(含 mchange_cast 型別轉換、啟動 preflight、checkpoint 規則指紋;Linux x86_64)|
| nimo-full-check.linux | 校驗工具(StarCo 改寫版,含 converge 二次收斂與規則覆蓋完整性閘門;`--version` 可查)|
| nimo-shake.conf | 設定檔(填 `id`、連線資訊即可用;`sync_mode=all`、`convert.type=mchange_cast`、23 表白名單已設)|
| nimo-shake.conf.example | 原始模板對照本(改壞了可以 diff 回來)|
| type_rules_opapp.json | 23 表 / 43 個受治理欄位轉型規則(v2 格式;兩工具共用;勿移動,conf 以相對路徑引用;`scope.database` 須改成 conf 的 `id`)|
| start.sh / stop.sh | 啟停腳本(用法同前版)|
| ChangeLog | 版本沿革(上游歷史保留 + StarCo 條目)|
| SHA256SUMS | 檔案指紋(`sha256sum -c SHA256SUMS` 可驗)|
| docs/ | 部署與使用說明、驗證報告 |

## 與前版(1.0.14-sc.20260818)的差異

- **規則檔改為 v2 格式(collection-scoped)**:規則以「表 + 頂層欄位」為作用域,同名欄位在不同表各自獨立;前版 v1 規則檔與本版**互斥**(本版程式吃到 v1 檔會在啟動摘要印 `schema=v1 ... scope_database=unbound`,前版程式吃到 v2 檔會拒載)
- **Int32 / Int64 由原始數值精確解析**:值直接從 DynamoDB 的 `N` 字串解析,不經過浮點;10 個 `expiration_date` 欄位轉 Int64(long),超過 2^53 的值不會被四捨五入;工具不判斷秒/毫秒、不轉 Date
- **5 個 seqno 欄位接受數字字串(N/S 混合)**:只在 `egtc_traded_m`、`event_record_traded_m`、`external_import_traded_m`、`imm_traded_m`、`mms_coupon_m` 五張表啟用;字串只接受正規十進位整數字面,**前導零(`"007"`)與負零(`"-0"`)一律拒轉並完整保留原字串**,校驗端列為 `SOURCE_UNCASTABLE` 並帶 `reason`(`LEADING_ZERO` / `NEGATIVE_ZERO` / `INVALID_INTEGER` 等)。沒有任何開關可以放寬
- **啟動 preflight**:啟動時檢查 ① 規則檔 `scope.database` 是否等於 conf 的 `id`;② 白名單解析出的表清單是否與規則檔宣告的 23 表完全相同(少一張、多一張、拼錯都擋,log 列 missing/extra);③ 規則欄位是否撞到該表的 Partition Key / Sort Key。任一不符 → 啟動即停,目的端與 checkpoint 零異動
- **啟動摘要三行**:每個程序只印一次,列出 schema、config_id/version、database、23/20/3/43 計數與規則檔 SHA256;校驗工具啟動時也印同格式摘要
- **checkpoint 規則指紋**:checkpoint 的 status 文件另記規則檔 SHA256、`config_version`、`convert.type`、`convert._id`、`database`;從 `incr_sync` 續跑時逐欄比對,不符則啟動即 error 退出(不續跑、不重跑、不 drop)
- **規則覆蓋完整性閘門**:`rule-coverage.json` 只註冊每表自己的規則(恰 43 列);任一受治理規則 `zero_hits` → `coverage_complete=false` → 整次升為 `EXECUTION_ERROR`(exit 2)。前版曾出現「規則沒碰到資料卻 PASS」的假象,本版由工具直接擋下
- **型別轉換模組的 log 已接上輸出**:前版轉型模組的 INFO/WARN 從未寫進 log 檔,本版統一修正;但驗收仍以 `rule-coverage.json` 為準,**不以「log 沒 WARN」推定正常**
- 前版 `start.sh` / `stop.sh` 的修正(正確 binary 名、pid 身分驗證、hypervisor 移除、darwin 執行檔移除)全部保留

## 已知限制

- ⚠️ `target.db.exist = drop`:每次走全量路徑都會**先清空目標 collection**(逐 collection);`start.sh` 會印警告。重跑全量前務必確認
- **白名單與黑名單都留空 = 全部同步**:此時以來源端實際解析出的表清單與規則檔的 23 表比對,仍受 preflight 保護;若來源帳號下有規則檔未宣告的其他表,會被 preflight 擋下(需改用白名單明列 23 表)
- **`scope.database` 必須等於 conf 的 `id`**,不符啟動即失敗;改 `id` 就必須同步改規則檔
- **checkpoint 規則指紋只保護「從 `incr_sync` 續跑」**:改了規則檔或 `config_version` 後以 `full` 重跑(或 checkpoint 狀態不是 `incr_sync`)**不會被指紋擋下**,會依 `target.db.exist` 重建全部 collection(等於一次完整的全量重跑)
- **file checkpoint 的落檔位置由 `checkpoint.db` 決定,不是 `checkpoint.address`**:`checkpoint.type = file` 時 `checkpoint.address` 被忽略;設相對路徑時落在啟動當時的工作目錄下。mongodb 模式不受影響
- **任何 `--resume` 的校驗都不作完整性證明**:續跑結果一律標 `coverage_complete=false`(原 `PASS` 升 exit 2);完整驗收須以不帶 `--resume` 的全量重跑取得
- nimo-shake 全量無斷點續傳:全量中斷後須整批重跑(並再次觸發 `drop`);增量階段可從 checkpoint 續接,但 DynamoDB Stream 只保留 24 小時
- pid 檔名 = conf 的 `id` 值(`<id>.pid`;`start.sh` 另複製一份為固定名 `nimo-shake.pid`);pid 檔寫在啟動當時的工作目錄
- **binary 為動態連結**(Go 1.20.14、CGO 啟用):客戶主機需有相容的 glibc(一般 x86_64 Linux 發行版即可);不是前版說明的靜態連結
- **以下情境在本機實驗室無法驗證,需在客戶環境補驗**:增量同步(`sync_mode = all`)、shard 交接、checkpoint 續跑判定(`CheckCkpt` 三態)、指紋不符時的拒絕啟動與錯誤訊息字面。原因:本機使用 DynamoDB Local 必須設 `source.endpoint_url`,而產品規定設了 endpoint 就只能 `sync_mode = full`。清單見 `docs/驗證報告_2026-09-17.md`
