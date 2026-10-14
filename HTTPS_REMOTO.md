# Manual Técnico — Diagnóstico e resolução de problemas HTTPS
## SisPatrimônio Pro

**Ambiente:** Pop!_OS + Ubuntu Server 24.04  
**Servidor:** `192.168.0.12`  
**Porta HTTPS:** `8000`  
**Serviço systemd:** `sispatrimoniopro`  
**Data do registro:** 13 e 14 de outubro de 2026

---

## 1. Objetivo

Documentar os problemas encontrados durante a configuração e a recuperação do acesso HTTPS ao SisPatrimônio Pro, suas causas, as correções aplicadas e os testes de validação.

## 2. Configuração do ambiente

| Componente | Configuração |
|---|---|
| Sistema cliente | Pop!_OS |
| Sistema servidor | Ubuntu Server 24.04 |
| Endereço do servidor | `192.168.0.12` |
| Porta da aplicação | `8000` |
| Endpoint de saúde | `https://192.168.0.12:8000/health` |
| Diretório da aplicação | `/opt/SisPatrimonioPro` |
| Usuário do serviço | `sispatrimonio` |
| Certificado do servidor | `/opt/SisPatrimonioPro/data/ssl/server.crt` |
| Chave privada do servidor | `/opt/SisPatrimonioPro/data/ssl/server.key` |
| Certificado da CA | `/opt/SisPatrimonioPro/data/ssl/ca.crt` |
| Diretório de CAs locais no cliente | `/usr/local/share/ca-certificates/` |

O servidor utiliza um certificado emitido por uma autoridade certificadora (CA) local. O cliente precisa confiar na CA que assinou o certificado do servidor.

## 3. Problema 1 — Serviço HTTPS não iniciava

### Sintoma

O serviço `sispatrimoniopro` falhava ao iniciar.

### Diagnóstico

No Ubuntu Server, foi executado:

```bash
sudo systemctl status sispatrimoniopro --no-pager -l
```

O log indicou:

```text
PermissionError: [Errno 13] Permission denied
```

A falha ocorria quando o Uvicorn tentava carregar o certificado e a chave privada TLS.

### Causa

Os arquivos pertenciam ao usuário `root`, mas o serviço era executado pelo usuário `sispatrimonio`. A chave privada estava com permissão `600`, impedindo que o usuário do serviço a lesse.

### Correção aplicada

```bash
sudo chown sispatrimonio:sispatrimonio \
  /opt/SisPatrimonioPro/data/ssl/server.crt \
  /opt/SisPatrimonioPro/data/ssl/server.key

sudo chmod 644 \
  /opt/SisPatrimonioPro/data/ssl/server.crt

sudo chmod 600 \
  /opt/SisPatrimonioPro/data/ssl/server.key

sudo systemctl start sispatrimoniopro
```

### Resultado

O serviço iniciou e o log passou a indicar que o Uvicorn estava executando em `https://0.0.0.0:8000`.

**Segurança:** mantenha a chave privada protegida. A permissão `600` permite leitura e escrita somente pelo proprietário. Não altere a chave para `644`.

## 4. Problema 2 — CA incorreta instalada no Pop!_OS

### Sintoma

O comando `curl` apresentava:

```text
SSL certificate problem: authority and subject key identifier mismatch
```

### Diagnóstico

Foram identificados certificados antigos no diretório:

```text
/usr/local/share/ca-certificates/
```

Arquivos encontrados:

```text
ca.crt
sispatrimonio-ca.crt
sispatrimonio-local-ca.crt
```

Os certificados antigos eram iguais entre si, mas não correspondiam à CA que assinou o certificado atualmente apresentado pelo servidor.

A CA atual do servidor estava em:

```text
/opt/SisPatrimonioPro/data/ssl/ca.crt
```

### Correção aplicada

No Pop!_OS, o certificado atual foi copiado do servidor:

```bash
scp wellington@192.168.0.12:/opt/SisPatrimonioPro/data/ssl/ca.crt \
  /tmp/sispatrimonio-ca-atual.crt
```

O arquivo copiado foi conferido e sua impressão digital SHA-256 correspondeu à CA atual do servidor.

Em seguida, foi instalado no diretório de autoridades certificadoras locais:

```bash
sudo cp /tmp/sispatrimonio-ca-atual.crt \
  /usr/local/share/ca-certificates/sispatrimonio-remoto-ca.crt

sudo update-ca-certificates
```

Na execução final registrada, o atualizador retornou:

```text
0 added, 0 removed; done.
```

Essa mensagem, isoladamente, não comprova a validade do certificado. A confirmação foi feita com o teste HTTPS da seção 6.

**Importante:** não apague certificados antigos indiscriminadamente. Antes de removê-los, verifique se são utilizados por outros sistemas ou aplicações.

## 5. Verificação da cadeia de certificados

No Ubuntu Server, foi executado:

```bash
openssl verify \
  -CAfile /opt/SisPatrimonioPro/data/ssl/ca.crt \
  /opt/SisPatrimonioPro/data/ssl/server.crt
```

Resultado obtido:

```text
/opt/SisPatrimonioPro/data/ssl/server.crt: OK
```

Isso confirma que o certificado do servidor foi validado com a CA indicada no comando. O teste não substitui a validação feita pelo cliente nem comprova, sozinho, a correspondência com o endereço acessado.

## 6. Validação final do HTTPS

No Pop!_OS, foi executado:

```bash
curl -v https://192.168.0.12:8000/health
```

A saída confirmou:

```text
SSL certificate verify ok.
```

Também confirmou que o IP acessado correspondia ao `subjectAltName` do certificado:

```text
subjectAltName: host "192.168.0.12" matched cert's IP address!
```

Resposta HTTP:

```text
HTTP/1.1 200 OK
```

Conteúdo retornado:

```json
{
  "status": "healthy",
  "application": "ok",
  "database": "ok",
  "ad": "not_applicable"
}
```

### Interpretação

| Verificação | Resultado |
|---|---|
| Conexão com o servidor | Aprovada |
| Negociação TLS | Aprovada |
| Confiança na CA | Aprovada |
| Correspondência do IP com o certificado | Aprovada |
| Resposta HTTP | `200 OK` |
| Aplicação | `ok` |
| Banco de dados | `ok` |
| AD | `not_applicable` |

O valor `ad: not_applicable` foi o retorno observado naquele teste; por si só, não indica uma falha de HTTPS.

**Conclusão:** o acesso HTTPS pelo Pop!_OS foi validado sem desativar a verificação do certificado.

## 7. Procedimento de diagnóstico futuro

### Etapa 1 — Verificar o serviço

No Ubuntu Server:

```bash
sudo systemctl status sispatrimoniopro --no-pager -l
```

Se houver falha, consulte os logs:

```bash
sudo journalctl -u sispatrimoniopro -n 100 --no-pager
```

### Etapa 2 — Verificar as permissões dos arquivos TLS

```bash
sudo ls -l /opt/SisPatrimonioPro/data/ssl/
```

Confirme que o usuário do serviço consegue ler `server.crt` e `server.key`. A chave privada deve continuar restrita ao usuário autorizado.

### Etapa 3 — Testar o endpoint local no servidor

```bash
curl -v https://127.0.0.1:8000/health
```

O endereço `127.0.0.1` pode não corresponder ao IP presente no certificado. Para testar localmente usando o IP incluído no certificado, execute:

```bash
curl --resolve 192.168.0.12:8000:127.0.0.1 \
  https://192.168.0.12:8000/health
```

Não use `-k` como validação definitiva, pois essa opção ignora a verificação do certificado.

### Etapa 4 — Testar a partir do Pop!_OS

```bash
curl -v https://192.168.0.12:8000/health
```

Interpretação dos erros comuns:

- **`Connection refused`:** verifique o serviço, o endereço e a porta.
- **`SSL certificate problem`:** confira a CA confiável, a validade, a cadeia e o nome/IP do certificado.
- **`HTTP 200 OK`:** o endpoint respondeu e a validação TLS foi aprovada.
- **Outro código HTTP:** investigue a aplicação e os logs; o problema pode não ser de TLS.

### Etapa 5 — Atualizar as CAs, se necessário

Depois de confirmar que o arquivo é a CA correta:

```bash
sudo update-ca-certificates
```

Repita o teste com `curl`.

### Etapa 6 — Confirmar no Chrome

1. Feche completamente o Chrome.
2. Abra-o novamente.
3. Acesse `https://192.168.0.12:8000`.
4. Confirme se a página abre sem aviso de certificado.

Se o `curl` funcionar e o Chrome continuar mostrando um aviso, investigue o armazenamento de certificados e o estado do navegador antes de alterar arquivos do sistema.

## 8. Cuidados de segurança

- Não compartilhe `server.key` nem `ca.key`.
- Distribua a CA pública por um canal confiável e confira sua impressão digital.
- Não instale o certificado do servidor como CA raiz, salvo se esse for deliberadamente o modelo de confiança adotado.
- Não remova certificados antigos sem verificar se têm dependências.
- Não use `curl -k` para concluir que o HTTPS está confiável.
- Não amplie as permissões da chave privada para todos os usuários.
- Após alterar certificados ou permissões, teste o serviço e consulte os logs.
- Se o certificado ou a CA forem substituídos, repita a validação no servidor e nos clientes.

## 9. Resumo das soluções

| Problema | Causa | Solução |
|---|---|---|
| Serviço não iniciava | Permissões incorretas nos arquivos TLS | Ajuste de proprietário e permissões de `server.crt` e `server.key` |
| Cliente rejeitava o certificado | CA antiga no Pop!_OS | Cópia e instalação da CA atual do servidor |
| Atualizador não indicava alterações | `update-ca-certificates` não registrou adições ou remoções naquela execução | Verificação efetiva com `curl` |
| Era necessário confirmar o funcionamento | Dúvida sobre cadeia de confiança e disponibilidade da aplicação | Testes com `openssl verify` e `curl` |

## 10. Estado final registrado

Ao término dos procedimentos:

- O serviço `sispatrimoniopro` estava iniciado.
- O endpoint `/health` retornava HTTP `200 OK`.
- O certificado correspondia ao IP `192.168.0.12`.
- A CA era reconhecida pelo sistema cliente.
- A validação TLS pelo `curl` foi concluída sem erros.

**Pendente de confirmação separada:** o acesso pelo Chrome deve ser testado no navegador. O resultado do `curl` confirma a confiança do sistema operacional, mas não comprova sozinho que o Chrome esteja livre de avisos.

---

**Documento de referência:** diagnóstico e resolução do HTTPS do SisPatrimônio Pro — Pop!_OS e Ubuntu Server 24.04.
