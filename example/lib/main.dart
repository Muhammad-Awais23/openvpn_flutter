import 'dart:io';

import 'package:flutter/material.dart';
import 'dart:async';

import 'package:openvpn_flutter/openvpn_flutter.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  late OpenVPN engine;
  VpnStatus? status;
  String? stage;
  bool _granted = false;
  @override
  void initState() {
    engine = OpenVPN(
      onVpnStatusChanged: (data) {
        setState(() {
          status = data;
        });
      },
      onVpnStageChanged: (data, raw) {
        setState(() {
          stage = raw;
        });
      },
    );

    engine.initialize(
      groupIdentifier: "group.com.laskarmedia.vpn",
      providerBundleIdentifier:
          "id.laskarmedia.openvpnFlutterExample.VPNExtension",
      localizedDescription: "VPN by Nizwar",
      lastStage: (stage) {
        setState(() {
          this.stage = stage.name;
        });
      },
      lastStatus: (status) {
        setState(() {
          this.status = status;
        });
      },
    );
    super.initState();
  }

  Future<void> initPlatformState() async {
    engine.connect(
      config,
      "USA",
      username: defaultVpnUsername,
      password: defaultVpnPassword,
      certIsRequired: true,
    );
    if (!mounted) return;
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Plugin example app'),
        ),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(stage?.toString() ?? VPNStage.disconnected.toString()),
              Text(status?.toJson().toString() ?? ""),
              TextButton(
                child: const Text("Start"),
                onPressed: () {
                  initPlatformState();
                },
              ),
              TextButton(
                child: const Text("STOP"),
                onPressed: () {
                  engine.disconnect();
                },
              ),
              if (Platform.isAndroid)
                TextButton(
                  child: Text(_granted ? "Granted" : "Request Permission"),
                  onPressed: () {
                    engine.requestPermissionAndroid().then((value) {
                      setState(() {
                        _granted = value;
                      });
                    });
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

const String defaultVpnUsername = "";
const String defaultVpnPassword = "";

String get config => '''
client
dev tun
proto udp
#remote 195.114.14.202 1201
remote 195.114.14.202 1202
remote 195.114.14.202 1203
remote-random
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
auth SHA256
data-ciphers AES-256-GCM
ignore-unknown-option block-outside-dns
block-outside-dns
verb 3
<ca>
-----BEGIN CERTIFICATE-----
MIIDSzCCAjOgAwIBAgIUS8vwcW/2bzZ11D5z8TtlG8+yZAowDQYJKoZIhvcNAQEL
BQAwFjEUMBIGA1UEAwwLRWFzeS1SU0EgQ0EwHhcNMjUwNDI0MTEyMDA0WhcNMzUw
NDIyMTEyMDA0WjAWMRQwEgYDVQQDDAtFYXN5LVJTQSBDQTCCASIwDQYJKoZIhvcN
AQEBBQADggEPADCCAQoCggEBALZxbAfgbYDb/RZWlUSQToLP8631v8yuqhHeT2IR
bFTXysy/zuCALmGtniIcwEvgZzP6B4dvHUJAvVTB8cs7g0P+FVf0Byd0KV5hXwLI
ZGlYgBqBVrWgcjcSw8RvS2EAghngpX1GbQ8tVnbXgl7eYxS0JQpD1V0XVzxHARer
1RrH+IeCjMDqrXjhcm2lM2O+rTeI6XeYHB9OM5Uh1V1kDwfFbwwThLPw+x1oDjF7
AJI0yfRhXNZogI+DeHyBS0TByE4+ik4r7FKh1xcoK/7i9BX7AzjEDl6bVUOdLRHk
udKV3gMmn9FklXwu5n/QqskSZuzDRV6KV6Pt7EDUmpfI1HECAwEAAaOBkDCBjTAM
BgNVHRMEBTADAQH/MB0GA1UdDgQWBBS0oh60TOtBgqOo7VNEWDuUj9qEpTBRBgNV
HSMESjBIgBS0oh60TOtBgqOo7VNEWDuUj9qEpaEapBgwFjEUMBIGA1UEAwwLRWFz
eS1SU0EgQ0GCFEvL8HFv9m82ddQ+c/E7ZRvPsmQKMAsGA1UdDwQEAwIBBjANBgkq
hkiG9w0BAQsFAAOCAQEALDmVZKiIdwGmk9sanPJ2G/ubEuBPYi1uc3OklQNSKP6x
ebI4xN2R4B9ECH/8TaBJ5xmEhaBg8ltwoE2iAOxcta0ExdmLuPGkvwEqBDbS3EQA
t2iG5oILkleV6VR6h7QxEjt6Qwao13ZOlQWxiQp5t/xicaG57TVp5FZzVbq1Yrvy
Wjr3OIrXtwKUWifdZzSIIMgtBtkdwZTRthV21b8s5oxHBxVLivTJ2hiSKzFgYrZr
6BgGX7LRpV9abFyzmJmATb0xqu/W4pP3QwZjXJMBdJwYtRqdICZg44TG/wSWFqQm
65S41NfAC1slwdWi2ivl/0DKuItUyhxykHYz2yTWRw==
-----END CERTIFICATE-----
</ca>
<cert>
-----BEGIN CERTIFICATE-----
MIIDYTCCAkmgAwIBAgIQD6h2zkVXB0eeM46+Y0tYlTANBgkqhkiG9w0BAQsFADAW
MRQwEgYDVQQDDAtFYXN5LVJTQSBDQTAeFw0yNTA0MjQxMTIwMDVaFw0zNTA0MjIx
MTIwMDVaMB4xHDAaBgNVBAMME25hay1hdS1zeWQtYm0tbXVsdGkwggEiMA0GCSqG
SIb3DQEBAQUAA4IBDwAwggEKAoIBAQDLnt4mikj45hm6RWCL4T6cltPcDurxTyem
/SXHJDK7XhCPr0ot1VxS1uXOEDHIogrMnvF60aAt8ix/+R5tyoMQZ7wsRMJ7Ggrd
EOJtBCH+CbyDKmGVVIQHvn+JeBRbi3HMuYT5fNg8q8FhCv2V0pzErGWoGfHlJxfo
opZHfHNeGUGEEATs1rsj2Ezkaqp8SzFsMydVAKO3kdtCOCjBVycUC3oMx4FSo3qo
6nE/YsLsoBmciW/rsI2zkaHtLMJMX/z8CuhLeTUrX1nwKFaEjfYl6IHYVXal4te0
o53IpTkBpC+6LIWVK9S1QshuhEVZhwdba2IAkaL7J5i2yQs3D0aDAgMBAAGjgaIw
gZ8wCQYDVR0TBAIwADAdBgNVHQ4EFgQUSNFlpOCxbwa6D4RYV7m2KU0xX98wUQYD
VR0jBEowSIAUtKIetEzrQYKjqO1TRFg7lI/ahKWhGqQYMBYxFDASBgNVBAMMC0Vh
c3ktUlNBIENBghRLy/Bxb/ZvNnXUPnPxO2Ubz7JkCjATBgNVHSUEDDAKBggrBgEF
BQcDAjALBgNVHQ8EBAMCB4AwDQYJKoZIhvcNAQELBQADggEBAFEJ0Jpr7/FD1/zt
flWYwZthFVYNV0KNtJEFyyG7yzrq+pj94oV0W8Ax5GBpNz+XNtVJ8Udb1TL9hk8v
ON1IZYKFfc87I5GGCuuMeICLsEfEDV4oS8LuKLfuIIApIUFABGInLNOgOnrvywo+
H0H71vKd3wFW4K86PKnRCjPkkDOrToX7ei1VJ6KCERp3Dm5A1IfzCm8ipQe85ESh
Uk4VGpPOIggI+fsFTdieYhrHPAiHCuc9oy4gJLy9i5sTSBUZWJvCshJHiYETYGhE
My8iePKqsYJOCR1xWmwWOC4ohrwLcaVbk9fLKdQmdiXFZ+d3IdIqOhTlX6KQpFUP
IHHsTnY=
-----END CERTIFICATE-----
</cert>
<key>
-----BEGIN PRIVATE KEY-----
MIIEvAIBADANBgkqhkiG9w0BAQEFAASCBKYwggSiAgEAAoIBAQDLnt4mikj45hm6
RWCL4T6cltPcDurxTyem/SXHJDK7XhCPr0ot1VxS1uXOEDHIogrMnvF60aAt8ix/
+R5tyoMQZ7wsRMJ7GgrdEOJtBCH+CbyDKmGVVIQHvn+JeBRbi3HMuYT5fNg8q8Fh
Cv2V0pzErGWoGfHlJxfoopZHfHNeGUGEEATs1rsj2Ezkaqp8SzFsMydVAKO3kdtC
OCjBVycUC3oMx4FSo3qo6nE/YsLsoBmciW/rsI2zkaHtLMJMX/z8CuhLeTUrX1nw
KFaEjfYl6IHYVXal4te0o53IpTkBpC+6LIWVK9S1QshuhEVZhwdba2IAkaL7J5i2
yQs3D0aDAgMBAAECggEAR05iwH9jz5oQ/2zFQycFnKOrHKCywP+1xKJZJPR1uazW
wuKhaQyTUMVF49RDAt5QRtkQerDHVd+9mrE8aTlmjYuuV5havO5hSIpdqMyuNL7n
H83rL3bR575b/mGpS2e5WfbL7Oy98v048sl9BYckdDFlRimTzupSUpsBYpZf9l7k
YihlILzXug1KDz84PvAFg5oC40W6SrGODEpVsdLx8pfOip6gwopPYdxqRAw+F1lV
rGfZjIWy96ZO0nSkFgRUjAZyz+TMGLi9gFptnSBhHaoWQQhAwAOXFOcIeeUAH2wK
x7xOHc9ZOtQ4uAh7opBFguE5NXtJo7ZMcfX9m65EfQKBgQDSTdGeQ7UBR55KATeM
kIo16K3miXOcb2pcvQ6IMKZlkbi2Jad1PqhQU+mIQ48foPxTMUDkBFN/5GDeTzUK
NXm26Ebu54TtGXkxrs6e/y2msPoQCV/FOqWsFFWO4DZdLkfHfvbiPReQzPaIydpG
kydNt9qoCcs0wDm1/euKlOW4hwKBgQD33Uiy7uoMjJ9tHF/NOOxAR43QczNrJJLE
9ORykW5ABbbV9+CUarp53evGzpFF4a892NS1SFfPvI87PWu5jfOoigCtr+Aua4m3
yLRuROjBHrpGsfgh+bMdzONPxCi4KQC/tPcB7UaZZ3s4LCegNP/HhkbYD9sdekU6
jgy1EY1NJQKBgBlpW83i4olADSlmEj9C6+BtuC2mKDkb4V9JXOsp7cFSJV6lGCH7
qzzhltNnTnEE89hdmDi1KR3IC8hxC7irE4T9dizB/vbjYBiXxdHChdKhieXMLC1Z
09ECOABmqUsDH5tEhTJ7LVDK43NN6LkkaNhkQeCSJmK+Y3rRLtf0+/kbAoGAE/FY
/RSd/j5+QVAsIR34XD+lmGT8eR1rNa+ihdlPrpUHHfYgurBPqqiBZPCP3biH2gkN
LDzS2+MG/zQ066wRM7lOzqq89d8vKHtckRa4R3mKcU+2cD1f/QDUNUHKKO8boVEV
IrGNoaAi2OUslwZMoigaoR29eoSw90IgoZz06oUCgYBPKVXnS+tTt69GehS9+J6e
Ijp6ulzleqhPwgTkFY4H/TN5NsczzxOirgjay7ORjVZx2grtCLOh+Nv/q1la5K/3
kwK3Bdsu2SRkfwPFT1EN5usvW/UnEHnIBO4NtRw08FKfzliI2/5YEsCzIk9Bt+AU
8oBwEYocRWT7qSZ3LEpdhQ==
-----END PRIVATE KEY-----
</key>
<tls-crypt>
-----BEGIN OpenVPN Static key V1-----
2d573c7917627cc010b199e92aa3019f
4de38e227aa00802db2efc95e7e57c75
05486f289f88a4ee4d98fdafe05f32af
20cd397a543217ba582e0b7431f852b2
3dda2e2ccc2eb3114042a6481f45b333
40519cc6ab00276ca2a858e7aa20f45a
106837118d4bfe89cabb9bf1753f5237
4de41a298fce43d63ce5ec44e7c5dad1
ebdca71af9c49505afd0bd81d2b1c1c7
3f916aa42925e8e2880a4a153970f5d1
51776400aace5ae5cbeeba7949446719
4aba76f929786b706214ebedbb0923fe
7b90bfaf6a23c83e69279b95c007c972
4dc85b4a3b906166878b95bed3e986aa
e51ac1e6da1bbfd38beab34d95998edc
0950d1967ccbc699fefe8af9e1b6caac
-----END OpenVPN Static key V1-----
</tls-crypt>
''';
