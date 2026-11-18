# zc 指令目录

## 目录

- [admin](#admin)
- [alias](#alias)
- [anonymous](#anonymous)
- [bucket](#bucket)
- [cat](#cat)
- [completions](#completions)
- [cors](#cors)
- [cp](#cp)
- [diff](#diff)
- [du](#du)
- [event](#event)
- [find](#find)
- [get](#get)
- [head](#head)
- [help](#help)
- [ilm](#ilm)
- [legalhold](#legalhold)
- [ls](#ls)
- [mb](#mb)
- [mirror](#mirror)
- [multipart](#multipart)
- [mv](#mv)
- [object](#object)
- [ping](#ping)
- [pipe](#pipe)
- [put](#put)
- [quota](#quota)
- [rb](#rb)
- [ready](#ready)
- [retention](#retention)
- [rm](#rm)
- [s3api](#s3api)
- [share](#share)
- [sql](#sql)
- [stat](#stat)
- [tag](#tag)
- [tree](#tree)
- [version](#version)
- [watch](#watch)

## admin

```text
zc admin access-key add
zc admin access-key create
zc admin access-key info
zc admin access-key list
zc admin access-key ls
zc admin access-key remove
zc admin access-key rm
zc admin access-key update
zc admin audit-events get
zc admin audit-events options get
zc admin audit-logs download
zc admin audit-logs get
zc admin audit-logs query
zc admin audit-logs set
zc admin auth login
zc admin auth logout
zc admin auth oidc backchannel-logout
zc admin auth oidc callback
zc admin auth oidc end-session
zc admin auth oidc logout
zc admin auth oidc providers
zc admin auth oidc refresh
zc admin auth oidc start
zc admin auth oidc web-identity
zc admin auth session
zc admin bucket configuration get
zc admin bucket configuration set
zc admin bucket create
zc admin bucket events get
zc admin bucket list
zc admin bucket objects get
zc admin bucket remove
zc admin bucket usage get
zc admin bucket versions get
zc admin bucket watch get
zc admin diagnostics get
zc admin diagnostics set
zc admin directory cleanup
zc admin directory create
zc admin directory remove
zc admin event-destination create
zc admin event-destination list
zc admin event-destination remove
zc admin event-destination set
zc admin event-subscription get
zc admin event-subscription set
zc admin group add
zc admin group add-members
zc admin group create
zc admin group disable
zc admin group enable
zc admin group info
zc admin group list
zc admin group ls
zc admin group remove
zc admin group rm
zc admin group rm-members
zc admin group update
zc admin health
zc admin idp openid disable
zc admin idp openid enable
zc admin idp openid get
zc admin idp openid list
zc admin idp openid set
zc admin idp openid update
zc admin idp openid validate
zc admin kms clear-cache
zc admin kms configure
zc admin kms info
zc admin kms key action
zc admin kms key cancel-deletion
zc admin kms key create
zc admin kms key delete
zc admin kms key list
zc admin kms key rotate
zc admin kms key schedule-deletion
zc admin kms key status
zc admin kms reconfigure
zc admin kms set
zc admin kms start
zc admin kms status
zc admin kms stop
zc admin logs download
zc admin logs get
zc admin logs query
zc admin logs set
zc admin monitoring
zc admin multipart abort
zc admin multipart complete
zc admin multipart create
zc admin multipart info
zc admin multipart list
zc admin object legalhold clear
zc admin object legalhold set
zc admin object presign
zc admin oidc validate invoke
zc admin oidc-provider create
zc admin oidc-provider disable
zc admin oidc-provider enable
zc admin oidc-provider info
zc admin oidc-provider list
zc admin oidc-provider remove
zc admin oidc-provider update
zc admin oidc-provider validate
zc admin organization create
zc admin organization list
zc admin organization remove
zc admin organization update
zc admin policy add
zc admin policy attach
zc admin policy create
zc admin policy detach
zc admin policy entities
zc admin policy info
zc admin policy list
zc admin policy ls
zc admin policy remove
zc admin policy rm
zc admin policy update
zc admin role create
zc admin role list
zc admin role remove
zc admin role update
zc admin role-session create
zc admin role-session list
zc admin role-session remove
zc admin role-session revoke
zc admin role-sessions revoke invoke
zc admin settings authentication get
zc admin settings authentication set
zc admin settings display get
zc admin settings display set
zc admin settings get
zc admin settings instance get
zc admin settings instance set
zc admin settings listener set
zc admin settings network set
zc admin settings region get
zc admin settings region set
zc admin storage gc
zc admin storage info
zc admin storage scanner
zc admin system
zc admin user access-key create
zc admin user access-key list
zc admin user access-key remove
zc admin user access-key update
zc admin user add
zc admin user create
zc admin user disable
zc admin user enable
zc admin user info
zc admin user list
zc admin user ls
zc admin user remove
zc admin user rm
zc admin user update
```

## alias

```text
zc alias export
zc alias import
zc alias info
zc alias list
zc alias remove
zc alias set
```

## anonymous

```text
zc anonymous get
zc anonymous get-json
zc anonymous links
zc anonymous list
zc anonymous set
zc anonymous set-json
```

## bucket

```text
zc bucket abac get
zc bucket abac set
zc bucket accelerate get
zc bucket accelerate set
zc bucket acl get
zc bucket acl set
zc bucket analytics get
zc bucket analytics list
zc bucket analytics remove
zc bucket analytics set
zc bucket anonymous get
zc bucket anonymous get-json
zc bucket anonymous links
zc bucket anonymous list
zc bucket anonymous set
zc bucket anonymous set-json
zc bucket cors clear
zc bucket cors get
zc bucket cors set
zc bucket create
zc bucket encryption clear
zc bucket encryption get
zc bucket encryption info
zc bucket encryption set
zc bucket event add
zc bucket event clear
zc bucket event get
zc bucket event list
zc bucket event remove
zc bucket event set
zc bucket intelligent-tiering get
zc bucket intelligent-tiering list
zc bucket intelligent-tiering remove
zc bucket intelligent-tiering set
zc bucket inventory get
zc bucket inventory list
zc bucket inventory remove
zc bucket inventory set
zc bucket lifecycle clear
zc bucket lifecycle get
zc bucket lifecycle set
zc bucket list
zc bucket location
zc bucket lock clear
zc bucket lock get
zc bucket lock info
zc bucket lock set
zc bucket logging get
zc bucket logging set
zc bucket metrics get
zc bucket metrics list
zc bucket metrics remove
zc bucket metrics set
zc bucket notification get
zc bucket notification set
zc bucket ownership clear
zc bucket ownership get
zc bucket ownership set
zc bucket policy clear
zc bucket policy get
zc bucket policy set
zc bucket policy status
zc bucket public-access-block clear
zc bucket public-access-block get
zc bucket public-access-block set
zc bucket quota clear
zc bucket quota info
zc bucket quota set
zc bucket remove
zc bucket request-payment get
zc bucket request-payment set
zc bucket stat
zc bucket tag clear
zc bucket tag get
zc bucket tag list
zc bucket tag remove
zc bucket tag set
zc bucket version enable
zc bucket version get
zc bucket version info
zc bucket version list
zc bucket version set
zc bucket version suspend
zc bucket website clear
zc bucket website get
zc bucket website set
```

## cat

```text
zc cat
```

## completions

```text
zc completions
```

## cors

```text
zc cors get
zc cors list
zc cors remove
zc cors set
```

## cp

```text
zc cp
```

## diff

```text
zc diff
```

## du

```text
zc du
```

## event

```text
zc event add
zc event clear
zc event get
zc event list
zc event remove
zc event set
```

## find

```text
zc find
```

## get

```text
zc get
```

## head

```text
zc head
```

## help

```text
zc help
zc help <指令>
zc <指令> --help
zc --help
zc --version
```

## ilm

```text
zc ilm restore
zc ilm rule add
zc ilm rule edit
zc ilm rule export
zc ilm rule import
zc ilm rule list
zc ilm rule remove
```

## legalhold

```text
zc legalhold clear
zc legalhold info
zc legalhold set
```

## ls

```text
zc ls
```

## mb

```text
zc mb
```

## mirror

```text
zc mirror
```

## multipart

```text
zc multipart abort
zc multipart complete
zc multipart copy-part
zc multipart create
zc multipart list
zc multipart parts
zc multipart upload-part
```

## mv

```text
zc mv
```

## object

```text
zc object acl get
zc object acl set
zc object annotation clear
zc object annotation get
zc object annotation list
zc object annotation set
zc object attributes
zc object copy
zc object encryption update
zc object find
zc object get
zc object head
zc object legal-hold clear
zc object legal-hold info
zc object legal-hold set
zc object legalhold clear
zc object legalhold disable
zc object legalhold enable
zc object legalhold get
zc object legalhold info
zc object legalhold set
zc object list
zc object list-v1
zc object move
zc object post
zc object put
zc object remove
zc object remove-batch
zc object restore
zc object retention clear
zc object retention get
zc object retention info
zc object retention set
zc object share
zc object show
zc object stat
zc object tag clear
zc object tag get
zc object tag list
zc object tag remove
zc object tag set
zc object torrent
zc object tree
```

## ping

```text
zc ping
```

## pipe

```text
zc pipe
```

## put

```text
zc put
```

## quota

```text
zc quota clear
zc quota info
zc quota set
```

## rb

```text
zc rb
```

## ready

```text
zc ready
```

## retention

```text
zc retention clear
zc retention info
zc retention set
```

## rm

```text
zc rm
```

## s3api

```text
zc s3api abort-multipart-upload
zc s3api complete-multipart-upload
zc s3api copy-object
zc s3api create-bucket
zc s3api create-multipart-upload
zc s3api delete-bucket
zc s3api delete-bucket-analytics-configuration
zc s3api delete-bucket-cors
zc s3api delete-bucket-encryption
zc s3api delete-bucket-intelligent-tiering-configuration
zc s3api delete-bucket-inventory-configuration
zc s3api delete-bucket-lifecycle
zc s3api delete-bucket-metrics-configuration
zc s3api delete-bucket-ownership-controls
zc s3api delete-bucket-policy
zc s3api delete-bucket-tagging
zc s3api delete-bucket-website
zc s3api delete-object
zc s3api delete-object-annotation
zc s3api delete-object-tagging
zc s3api delete-objects
zc s3api delete-public-access-block
zc s3api get-bucket-abac
zc s3api get-bucket-accelerate-configuration
zc s3api get-bucket-acl
zc s3api get-bucket-analytics-configuration
zc s3api get-bucket-cors
zc s3api get-bucket-encryption
zc s3api get-bucket-intelligent-tiering-configuration
zc s3api get-bucket-inventory-configuration
zc s3api get-bucket-lifecycle
zc s3api get-bucket-lifecycle-configuration
zc s3api get-bucket-location
zc s3api get-bucket-logging
zc s3api get-bucket-metrics-configuration
zc s3api get-bucket-notification
zc s3api get-bucket-notification-configuration
zc s3api get-bucket-ownership-controls
zc s3api get-bucket-policy
zc s3api get-bucket-policy-status
zc s3api get-bucket-request-payment
zc s3api get-bucket-tagging
zc s3api get-bucket-versioning
zc s3api get-bucket-website
zc s3api get-object
zc s3api get-object-acl
zc s3api get-object-annotation
zc s3api get-object-attributes
zc s3api get-object-legal-hold
zc s3api get-object-lock-configuration
zc s3api get-object-retention
zc s3api get-object-tagging
zc s3api get-object-torrent
zc s3api get-public-access-block
zc s3api head-bucket
zc s3api head-object
zc s3api list-bucket-analytics-configurations
zc s3api list-bucket-intelligent-tiering-configurations
zc s3api list-bucket-inventory-configurations
zc s3api list-bucket-metrics-configurations
zc s3api list-buckets
zc s3api list-multipart-uploads
zc s3api list-object-annotations
zc s3api list-object-versions
zc s3api list-objects
zc s3api list-objects-v2
zc s3api list-parts
zc s3api put-bucket-abac
zc s3api put-bucket-accelerate-configuration
zc s3api put-bucket-acl
zc s3api put-bucket-analytics-configuration
zc s3api put-bucket-cors
zc s3api put-bucket-encryption
zc s3api put-bucket-intelligent-tiering-configuration
zc s3api put-bucket-inventory-configuration
zc s3api put-bucket-lifecycle
zc s3api put-bucket-lifecycle-configuration
zc s3api put-bucket-logging
zc s3api put-bucket-metrics-configuration
zc s3api put-bucket-notification
zc s3api put-bucket-notification-configuration
zc s3api put-bucket-ownership-controls
zc s3api put-bucket-policy
zc s3api put-bucket-request-payment
zc s3api put-bucket-tagging
zc s3api put-bucket-versioning
zc s3api put-bucket-website
zc s3api put-object
zc s3api put-object-acl
zc s3api put-object-annotation
zc s3api put-object-legal-hold
zc s3api put-object-lock-configuration
zc s3api put-object-retention
zc s3api put-object-tagging
zc s3api put-public-access-block
zc s3api restore-object
zc s3api select-object-content
zc s3api update-object-encryption
zc s3api upload-part
zc s3api upload-part-copy
```

## share

```text
zc share
zc share post
```

## sql

```text
zc sql
```

## stat

```text
zc stat
```

## tag

```text
zc tag clear
zc tag get
zc tag list
zc tag remove
zc tag set
```

## tree

```text
zc tree
```

## version

```text
zc version
zc version enable
zc version get
zc version info
zc version list
zc version set
zc version suspend
```

## watch

```text
zc watch
```
