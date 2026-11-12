#!/usr/bin/env python3
"""Real OIDC code+PKCE, RS256/JWKS, BFF cookie and S3 credential regressions."""
import argparse
import base64
import datetime
import hashlib
import hmac
import http.cookiejar
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
sys.dont_write_bytecode = True
from user_access_keys import free_port


def b64(data):
    return base64.urlsafe_b64encode(data).decode().rstrip('=')

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None

def browser():
    return urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()), NoRedirect())

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--admin-bin', required=True, type=Path)
    parser.add_argument('--zig-bin', default=Path('zigfs/zig-out/bin/zigfs'), type=Path)
    args = parser.parse_args()
    processes = []
    with tempfile.TemporaryDirectory(prefix='zigfs-oidc-login-') as directory:
        root = Path(directory)
        key = root / 'key.pem'
        subprocess.run(['openssl', 'genpkey', '-algorithm', 'RSA', '-pkeyopt', 'rsa_keygen_bits:2048', '-out', str(key)], check=True, capture_output=True)
        n = subprocess.check_output(['openssl', 'rsa', '-in', str(key), '-noout', '-modulus']).decode().strip().split('=')[1]
        modulus = b64(bytes.fromhex(n))
        api_port, bff_port, idp_port = free_port(), free_port(), free_port()
        api = f'http://127.0.0.1:{api_port}'
        bff = f'http://127.0.0.1:{bff_port}'
        issuer = f'http://127.0.0.1:{idp_port}'
        mode = {'value': 'valid', 'auth': 'post', 'algorithm':'RS256', 'refresh_behavior':'valid'}
        refresh_tokens = set()
        env_providers = []
        signing_keys = {}
        for algorithm,curve in [('ES256','prime256v1'),('ES384','secp384r1'),('EdDSA','Ed25519')]:
            private=root/(algorithm+'.pem')
            command=['openssl','genpkey','-algorithm','ED25519','-out',str(private)] if algorithm=='EdDSA' else ['openssl','ecparam','-name',curve,'-genkey','-noout','-out',str(private)]
            subprocess.run(command,check=True,capture_output=True)
            public=subprocess.check_output(['openssl','pkey','-in',str(private),'-pubout','-outform','DER'])
            if algorithm=='EdDSA': jwk=dict(kty='OKP',crv='Ed25519',x=b64(public[-32:]))
            else:
                width=32 if algorithm=='ES256' else 48
                point=public[-2*width:]
                jwk=dict(kty='EC',crv='P-256' if width==32 else 'P-384',x=b64(point[:width]),y=b64(point[width:]))
            signing_keys[algorithm]=(private,jwk)
        def signing_jwk():
            alg=mode['algorithm']
            jwk=signing_keys[alg][1].copy() if alg in signing_keys else dict(kty='RSA',n=modulus,e='AQAB')
            jwk.update(alg=alg,use='sig',kid='rotation-2' if mode['value']=='rotated' else 'key-1',key_ops=['sign'] if mode['value']=='keyops' else ['verify'])
            return jwk
        def sign(content):
            alg=mode['algorithm']
            private=signing_keys[alg][0] if alg in signing_keys else key
            if alg=='EdDSA':
                message=root/'message.bin';message.write_bytes(content)
                return subprocess.check_output(['openssl','pkeyutl','-sign','-rawin','-inkey',str(private),'-in',str(message)])
            command=['openssl','dgst','-sha'+alg[-3:],'-sign',str(private)]
            if alg.startswith('PS'): command+=['-sigopt','rsa_padding_mode:pss','-sigopt','rsa_pss_saltlen:digest']
            signature=subprocess.run(command,input=content,capture_output=True,check=True).stdout
            if alg.startswith('ES'):
                # Convert OpenSSL DER r/s to the fixed-width JOSE signature form.
                offset=2 if signature[1]<128 else 2+(signature[1]&127)
                values=[]
                for _ in range(2):
                    assert signature[offset]==2
                    size=signature[offset+1];offset+=2
                    values.append(int.from_bytes(signature[offset:offset+size],'big'));offset+=size
                width=32 if alg=='ES256' else 48
                signature=b''.join(v.to_bytes(width,'big') for v in values)
            return signature
        codes = {}
        tokens = []
        def jwt(nonce):
            now = int(time.time())
            claims = dict(iss=issuer, sid='external-session', sub='external-user', aud='console', iat=now, exp=now+600, nonce=nonce, groups=['browser-reader'], preferred_username='qa', email='qa@example.test')
            kind = mode['value']
            if kind == 'refresh': claims['exp'] = now+45
            if kind == 'refreshed':
                claims['preferred_username']='updated-name'; claims['email']='updated@example.test'; claims.pop('nonce',None)
                if mode['refresh_behavior']=='subject': claims['sub']='different-user'
                if mode['refresh_behavior']=='nonce': claims['nonce']='different-nonce'
            if kind == 'audience': claims['aud'] = 'other-client'
            if kind == 'malformed_audience': claims['aud']=['console',42]; claims['azp']='console'
            if kind == 'issuer': claims['iss'] = 'https://evil.example'
            if kind == 'expired': claims['exp'] = now-1
            if kind == 'nonce': claims['nonce'] = 'wrong'
            if kind == 'nbf': claims['nbf'] = now+500
            if kind == 'azp': claims['aud'] = ['console', 'other']; claims['azp'] = 'other'
            if kind == 'nopolicy': claims['groups'] = []
            if kind == 'unknownpolicy': claims['groups'] = ['unknown-policy']
            header = dict(alg=mode['algorithm'], kid='rotation-2' if kind == 'rotated' else 'key-1')
            if kind == 'none': header['alg'] = 'none'
            if kind == 'critical': header['crit'] = ['unknown']
            content = b64(json.dumps(header).encode()) + '.' + b64(json.dumps(claims).encode())
            signature = sign(content.encode())
            if kind == 'signature': signature = bytes([signature[0] ^ 1]) + signature[1:]
            return content + '.' + b64(signature)
        class IdP(BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def respond(self, body, status=200):
                data = json.dumps(body).encode()
                self.send_response(status); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)
            def do_GET(self):
                path = urllib.parse.urlsplit(self.path)
                if path.path == '/.well-known/openid-configuration':
                    return self.respond(dict(issuer=issuer, authorization_endpoint=issuer+'/authorize', token_endpoint=issuer+'/token', jwks_uri=issuer+'/jwks', end_session_endpoint=issuer+'/logout', token_endpoint_auth_methods_supported=['client_secret_'+mode['auth']]))
                if path.path == '/jwks':
                    return self.respond(dict(keys=[signing_jwk()]))
                if path.path == '/authorize':
                    q = {k:v[0] for k,v in urllib.parse.parse_qs(path.query).items()}
                    assert q['code_challenge_method'] == 'S256' and q['response_type'] == 'code'
                    code = 'code-' + str(len(codes))
                    codes[code] = q
                    self.send_response(302); self.send_header('Location', q['redirect_uri']+'?'+urllib.parse.urlencode(dict(code=code, state=q['state']))); self.end_headers(); return
                self.respond({}, 404)
            def do_POST(self):
                q = {k:v[0] for k,v in urllib.parse.parse_qs(self.rfile.read(int(self.headers['Content-Length'])).decode()).items()}
                if mode['auth'] == 'basic':
                    if self.headers.get('Authorization') != 'Basic '+base64.b64encode(b'console:mock-client-secret').decode(): return self.respond({'error':'invalid_client'},401)
                    q['client_secret']='mock-client-secret'
                if q.get('client_id')!='console' or q.get('client_secret')!='mock-client-secret': return self.respond({'error':'invalid_client'},401)
                if q.get('grant_type') == 'refresh_token':
                    if mode['refresh_behavior']=='revoked': return self.respond({'error':'invalid_grant'},400)
                    if q.get('refresh_token') not in refresh_tokens: return self.respond({'error':'invalid_grant'},400)
                    refresh_tokens.remove(q['refresh_token'])
                    mode['value']='refreshed'
                    token=jwt('')
                    refresh_tokens.add('rotated-refresh')
                    return self.respond(dict(id_token=token,refresh_token='rotated-refresh',access_token='unused'))
                saved = codes.pop(q['code'], None)
                if mode['auth'] == 'basic':
                    assert self.headers.get('Authorization') == 'Basic '+base64.b64encode(b'console:mock-client-secret').decode()
                    q['client_secret'] = 'mock-client-secret'
                if saved is None or q.get('client_secret') != 'mock-client-secret' or q.get('client_id') != 'console' or q.get('redirect_uri') != saved['redirect_uri'] or b64(hashlib.sha256(q.get('code_verifier', '').encode()).digest()) != saved['code_challenge']:
                    return self.respond({'error':'invalid_grant'}, 400)
                token = jwt(saved['nonce']); tokens.append(token)
                response = dict(id_token=token, access_token='not-used', token_type='Bearer')
                if mode['value']=='refresh': response['refresh_token']='initial-refresh'; refresh_tokens.add('initial-refresh')
                self.respond(response)
        server = ThreadingHTTPServer(('127.0.0.1', idp_port), IdP)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        config = root / '.env'
        config.write_text(f'''
ZIGFS_API_ADDRESS=127.0.0.1:{api_port}
ZIGFS_METRICS_ENABLED=false
ZIGFS_DATA_ROOT={root}/data
ZIGFS_ROOT_USER=qa
ZIGFS_ROOT_PASSWORD=oidc-test-only-password
ZIGFS_ADMIN_SESSION_SECRET=oidc-test-only-session-secret-123456789
''')
        log = (root / 'services.log').open('w')
        def call(client, url, method='GET', body=None, status=200):
            req = urllib.request.Request(url, method=method, data=json.dumps(body).encode() if body is not None else None, headers={'Content-Type':'application/json'})
            try: res = client.open(req, timeout=30)
            except urllib.error.HTTPError as err: res = err
            data = res.read()
            assert res.status == status, (method, urllib.parse.urlsplit(url).path, res.status, status)
            return res.headers, json.loads(data) if data and res.headers.get('Content-Type','').startswith('application/json') else data
        admin = browser()
        def req(path, method='GET', body=None, status=200, client=admin):
            return call(client, bff+'/api/v1'+path, method, body, status)[1]
        def ready(base):
            for _ in range(200):
                try:
                    if urllib.request.urlopen(base+'/health/ready', timeout=1).status == 200: return
                except OSError: pass
                time.sleep(.05)
            raise RuntimeError('readiness failed')
        def start_zig():
            p = subprocess.Popen([str(args.zig_bin.resolve()), '--env-file', str(config)], env=dict(os.environ,ZIGFS_OIDC_PROVIDERS=json.dumps(env_providers)),stdout=log, stderr=log); processes.append(p); ready(api); return p
        def root_login(): req('/auth/login', 'POST', dict(username='qa', password='oidc-test-only-password'))
        def login(kind='valid', success=True, provider_id='mock'):
            mode['value'] = kind
            user = browser()
            h, _ = call(user, bff+'/api/v1/auth/oidc/'+provider_id+'/start', status=303)
            h, _ = call(user, h['Location'], status=302)
            callback_url = h['Location']
            h, _ = call(user, callback_url, status=303)
            assert ('oidc_error' not in h['Location']) == success, (kind, h['Location'])
            if success:
                session = req('/auth/session', client=user)
                assert not session['is_root'] and session['subject_id'] != 'deployment-root' and session['username'] != 'qa'
                req('/system', status=403, client=user)
                req('/oidc/providers', status=403, client=user)
                req('/buckets', client=user)
            return user, callback_url
        try:
            zig = start_zig()
            processes.append(subprocess.Popen([str(args.admin_bin.resolve())], env=dict(os.environ, ZIGFS_ADMIN_LISTEN=f'127.0.0.1:{bff_port}', ZIGFS_ENDPOINT=api), stdout=log, stderr=log)); ready(bff)
            root_login()
            policy = json.dumps(dict(Version='2012-10-17', Statement=[dict(Effect='Allow', Action=['s3:ListAllMyBuckets'], Resource=['*'])]))
            req('/policies', 'POST', dict(name='browser-reader', document=policy), 201)
            provider = dict(provider_id='mock', display_name='Mock IdP', enabled=True, configuration_url=issuer+'/.well-known/openid-configuration', client_id='console', client_secret='mock-client-secret', redirect_uri=bff+'/api/v1/auth/oidc/callback')
            req('/oidc/providers', 'POST', provider, 201)
            req('/oidc/validate', 'POST', provider)
            assert req('/auth/oidc/providers')['items'][0]['provider_id'] == 'mock'
            refresh_user,_=login('refresh')
            before=req('/auth/session',client=refresh_user)
            assert before['display_name']=='qa' and before['email']=='qa@example.test' and before['refreshable']
            renewed=req('/auth/oidc/refresh','POST',client=refresh_user)
            assert renewed['display_name']=='updated-name' and renewed['email']=='updated@example.test' and renewed['expires_at']>before['expires_at']
            assert req('/auth/session',client=refresh_user)['display_name']=='updated-name'
            ended=req('/auth/oidc/end-session','POST',client=refresh_user)
            assert ended['logout_url'].startswith(issuer+'/logout?') and 'id_token_hint=' in ended['logout_url']
            req('/auth/session',status=401,client=refresh_user)
            assert 'initial-refresh' not in refresh_tokens and 'rotated-refresh' in refresh_tokens
            for behavior in ['subject','nonce','revoked']:
                mode['refresh_behavior']=behavior
                rejected,_=login('refresh')
                req('/auth/oidc/refresh','POST',status=401,client=rejected)
                req('/auth/session',status=401,client=rejected)
            mode['refresh_behavior']='valid'
            user, callback_url = login()
            # Same code/state cannot replay, even with a fresh browser.
            h, _ = call(user, callback_url, status=303); assert 'oidc_error' in h['Location']
            jar = next(h.cookiejar for h in user.handlers if isinstance(h, urllib.request.HTTPCookieProcessor))
            saved_cookie = '; '.join(c.name+'='+c.value for c in jar)
            req('/auth/logout', 'POST', status=204, client=user)
            stolen = urllib.request.Request(bff+'/api/v1/auth/session', headers={'Cookie':saved_cookie})
            try: stolen_response = urllib.request.urlopen(stolen)
            except urllib.error.HTTPError as err: stolen_response = err
            assert stolen_response.status == 401
            stolen_response.close()
            req('/auth/session', status=401, client=user)
            for kind in ['nonce','audience','issuer','expired','signature','none','nbf','azp','nopolicy','unknownpolicy','critical','keyops','malformed_audience']:
                login(kind, False)
            for algorithm in ['RS384','RS512','PS256','PS384','PS512','ES256','ES384','EdDSA']:
                mode['algorithm']=algorithm
                login()
                login('signature',False)
            mode['algorithm']='RS256'
            user, _ = login('rotated')
            mode['auth'] = 'basic'
            user, _ = login()
            mode['auth'] = 'post'
            req('/oidc/providers/mock', 'PATCH', dict(provider, dynamic_redirect=True, redirect_uri=bff+'/ignored/path'))
            mode['value'] = 'valid'
            user, _ = login()
            identity_token = tokens[-1]
            credentials = req('/auth/oidc/web-identity', 'POST', dict(provider_id='mock', web_identity_token=identity_token), 201)
            def s3(creds, status=200, token=True):
                now = datetime.datetime.now(datetime.timezone.utc)
                date, stamp = now.strftime('%Y%m%d'), now.strftime('%Y%m%dT%H%M%SZ')
                payload_hash = hashlib.sha256(b'').hexdigest()
                headers = {'host':f'127.0.0.1:{api_port}', 'x-amz-date':stamp, 'x-amz-content-sha256':payload_hash}
                if token: headers['x-amz-security-token'] = creds['session_token']
                names = ';'.join(sorted(headers))
                canonical = '\n'.join(['GET','/','', ''.join(f'{k}:{headers[k]}\n' for k in sorted(headers)),names,payload_hash])
                scope = date+'/us-east-1/s3/aws4_request'
                msg = '\n'.join(['AWS4-HMAC-SHA256',stamp,scope,hashlib.sha256(canonical.encode()).hexdigest()])
                signing = ('AWS4'+creds['secret_key']).encode()
                for part in [date,'us-east-1','s3','aws4_request']: signing = hmac.new(signing,part.encode(),hashlib.sha256).digest()
                headers['Authorization'] = f"AWS4-HMAC-SHA256 Credential={creds['access_key']}/{scope}, SignedHeaders={names}, Signature={hmac.new(signing,msg.encode(),hashlib.sha256).hexdigest()}"
                try: res = urllib.request.urlopen(urllib.request.Request(api+'/',headers=headers),timeout=10)
                except urllib.error.HTTPError as err: res = err
                assert res.status == status, ('s3',res.status,status)
                res.read()
            s3(credentials)
            form = dict(Action='AssumeRoleWithWebIdentity', Version='2011-06-15', RoleArn='arn:aws:iam::000000000000:role/oidc/mock', RoleSessionName='integration', WebIdentityToken=identity_token)
            def sts(fields, status=200):
                request = urllib.request.Request(api+'/', data=urllib.parse.urlencode(fields).encode(), headers={'Content-Type':'application/x-www-form-urlencoded'})
                try: response = urllib.request.urlopen(request, timeout=30)
                except urllib.error.HTTPError as err: response = err
                body = response.read()
                assert response.status == status, ('sts',response.status,status,body)
                return ET.fromstring(body)
            xml = sts(form)
            ns = {'s':'https://sts.amazonaws.com/doc/2011-06-15/'}
            sts_credentials = {name:xml.find('.//s:'+tag,ns).text for name,tag in [('access_key','AccessKeyId'),('secret_key','SecretAccessKey'),('session_token','SessionToken')]}
            s3(sts_credentials)
            managed=sts(dict(form, **{'PolicyArns.member.1.arn':'arn:aws:iam::000000000000:policy/browser-reader','ProviderId':issuer,'DurationSeconds':'43200'}))
            assert managed.find('.//s:SubjectFromWebIdentityToken',ns).text=='external-user'
            assert managed.find('.//s:Provider',ns).text==issuer
            assert managed.find('.//s:Audience',ns).text=='console'
            sts(dict(form, **{'PolicyArns.member.1.arn':'arn:aws:iam::000000000000:policy/missing'}),400)
            sts(dict(form,ProviderId='https://wrong.example'),400)
            sts(dict(form,RoleSessionName='x'),400)
            sts(dict(form,DurationSeconds='43201'),400)
            sts(dict(form,Policy=' '*2049),400)
            sts(dict(form,**{'PolicyArns.member.2.arn':'arn:aws:iam::000000000000:policy/browser-reader'}),400)
            assert sts(dict(form,RoleSessionName='test+=,.@-_')).find('.//s:Credentials',ns) is not None
            req('/policies','POST',dict(name='sts-deny',document=json.dumps(dict(Version='2012-10-17',Statement=[dict(Effect='Deny',Action='s3:*',Resource='*')]))),201)
            denied_xml=sts(dict(form,**{'PolicyArns.member.1.arn':'arn:aws:iam::000000000000:policy/sts-deny'}))
            denied_credentials={name:denied_xml.find('.//s:'+tag,ns).text for name,tag in [('access_key','AccessKeyId'),('secret_key','SecretAccessKey'),('session_token','SessionToken')]}
            s3(denied_credentials,403)
            s3(credentials,403,False)
            restricted = req('/auth/oidc/web-identity', 'POST', dict(provider_id='mock',web_identity_token=identity_token,session_policy=json.dumps(dict(Version='2012-10-17',Statement=[dict(Effect='Deny',Action='s3:*',Resource='*')]))),201)
            s3(restricted,403)
            zig.terminate(); zig.wait(timeout=10); zig=start_zig()
            req('/auth/session',client=user); s3(credentials)
            root_login()
            req('/oidc/providers/mock','PATCH',dict(provider,enabled=False,client_secret=''))
            req('/auth/session',status=401,client=user); s3(credentials,403)
            req('/auth/oidc/web-identity','POST',dict(provider_id='mock',web_identity_token=identity_token),401)
            assert req('/auth/oidc/providers')['items'] == []
            req('/oidc/providers/mock','DELETE',status=204)
            req('/oidc/providers','POST',provider,201)
            req('/auth/session',status=401,client=user); s3(credentials,403); s3(sts_credentials,403)
            user, _ = login()
            logout_claims=dict(iss=issuer,aud='console',iat=int(time.time()),jti='logout-once',sid='external-session',events={'http://schemas.openid.net/event/backchannel-logout':{}})
            content=b64(json.dumps(dict(alg='RS256',kid='key-1')).encode())+'.'+b64(json.dumps(logout_claims).encode())
            signature=subprocess.run(['openssl','dgst','-sha256','-sign',str(key)],input=content.encode(),capture_output=True,check=True).stdout
            logout_token=content+'.'+b64(signature)
            def backchannel(status):
                request=urllib.request.Request(bff+'/api/v1/auth/oidc/mock/backchannel-logout',data=urllib.parse.urlencode(dict(logout_token=logout_token)).encode())
                try: response=urllib.request.urlopen(request,timeout=30)
                except urllib.error.HTTPError as err: response=err
                assert response.status==status, ('backchannel',response.status,status)
                response.close()
            backchannel(200)
            req('/auth/session',status=401,client=user)
            backchannel(400)
            zig.terminate();zig.wait(timeout=10);zig=start_zig();root_login()
            backchannel(400)
            user,_=login()
            env_providers.append(dict(provider,provider_id='environment',display_name='Environment IdP'))
            zig.terminate(); zig.wait(timeout=10); zig=start_zig();root_login()
            environment=next(p for p in req('/oidc/providers')['items'] if p['provider_id']=='environment')
            assert environment['environment_managed'] and not environment['client_secret']
            req('/oidc/providers/environment','DELETE',status=409)
            req('/oidc/providers/environment','PATCH',dict(env_providers[0],client_secret=''),409)
            env_user,_=login(provider_id='environment')
            zig.terminate();zig.wait(timeout=10);zig=start_zig();root_login()
            req('/auth/session',client=env_user)
            env_providers.clear()
            zig.terminate();zig.wait(timeout=10);zig=start_zig();root_login()
            req('/auth/session',status=401,client=env_user)
            assert all(p['provider_id']!='environment' for p in req('/oidc/providers')['items'])
            deny = json.dumps(dict(Version='2012-10-17',Statement=[dict(Effect='Deny',Action='s3:*',Resource='*')]))
            req('/policies/browser-reader','PATCH',dict(name="browser-reader",document=deny))
            req('/buckets',status=403,client=user)
            print('PASS: 9 JWT algorithms, PKCE, profile/refresh rotation, RP/backchannel logout, environment ownership/restart, STS parameters/managed restrictions and signed S3 authorization')
        finally:
            for p in reversed(processes):
                if p.poll() is None: p.terminate(); p.wait(timeout=10)
            server.shutdown(); server.server_close(); log.close()
if __name__ == '__main__': main()
