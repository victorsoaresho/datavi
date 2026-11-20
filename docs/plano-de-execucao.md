# Plano de execução: PoC do Airbyte na Magalu Cloud

## Objetivo

Testar se o **Airbyte** serve como ferramenta de extração de dados. O teste é um fluxo completo na Magalu Cloud (MGC):

```
MySQL (DBaaS MGC)  ──►  Airbyte (Kubernetes MGC)  ──►  Bucket (Object Storage MGC)
 dataset público          source → connection → destination      arquivos Parquet/JSONL
```

**Premissa:** o ambiente é **temporário**. Toda a infra é criada com Terraform quando formos programar ou testar, e destruída ao final. Só o bucket de state do Terraform fica permanente. Por isso a configuração do Airbyte (sources, destinations e connections) também fica em código, para poder ser recriada a cada ciclo.

## Visão geral das fases

| Fase | Entrega | Permanente? |
|---|---|---|
| 0. Acessos e ferramentas | Credenciais da MGC e CLIs instaladas | — |
| 1. Bootstrap | Bucket `dataplat-state` para o state remoto | Sim |
| 2. Rede e cluster | VPC, security groups e cluster Kubernetes (MKS) | Não |
| 3. Banco e storage | MySQL (DBaaS) e bucket de destino | Não |
| 4. Carga do dataset | MySQL populado com dados públicos | Não |
| 5. Airbyte no cluster | Airbyte instalado via Helm | Não |
| 6. Fluxo como código | Source, destination e connection via Terraform | Não |
| 7. Testes de extração | Execuções e métricas registradas | Resultado em `docs/` |
| 8. Teardown | Tudo destruído, exceto o bucket de state | — |
| 9. Conclusão | ADR com o veredito sobre o Airbyte | Sim |

Itens marcados **⚠️ verificar** não foram confirmados na documentação oficial e precisam ser validados durante a execução.

---

## Fase 0: Acessos e ferramentas

### 0.1 Ferramentas locais (macOS)

```bash
brew install terraform kubectl helm mysql-client
brew install magalucloud/mgc/mgccli
mgc --version
```

Versões mínimas: Terraform `>= 1.11`, provider `MagaluCloud/mgc` (última estável: `0.56.x`, out/2026).

### 0.2 Credenciais da MGC

1. **Login na CLI:** `mgc auth login` (abre o navegador).
2. **API key geral**, usada pelo provider Terraform:
   - Console em https://id.magalu.com/api-keys → **Criar API Key**.
   - Defina um nome (ex.: `datavi-terraform`) e uma expiração curta.
   - Selecione os produtos usados no projeto: Kubernetes, DBaaS, Network, Object Storage e Virtual Machine.
   - Alternativa pela CLI: `mgc auth api-key create --name="datavi-terraform"`.
   - A CLI pode falhar com `cannot unmarshal ... PlatformsResponse`. Na prática, a API responde 403 ao listar escopos com login de conta pessoal. Nesse caso, use o console.
   - A sessão do `mgc auth login` **não** serve para o Terraform: o provider exige `api_key`.
3. **Key pair do Object Storage:** vem junto com a API key (`mgc auth api-key get <id>` mostra API Key, Key Pair ID e Key Pair Secret). É usado pelo provider, pelo backend S3 do Terraform e pelo destination do Airbyte.

### 0.3 Guardar as credenciais (fora do Git)

Crie um `.envrc` local (já ignorado pelo `.gitignore`):

```bash
export TF_VAR_mgc_api_key="..."            # API Key
export TF_VAR_mgc_key_pair_id="..."        # Key Pair ID (Object Storage)
export TF_VAR_mgc_key_pair_secret="..."    # Key Pair Secret (Object Storage)
export AWS_ACCESS_KEY_ID="$TF_VAR_mgc_key_pair_id"          # backend S3
export AWS_SECRET_ACCESS_KEY="$TF_VAR_mgc_key_pair_secret"  # backend S3
```

O modelo versionado, sem valores, está em `.envrc.example`.

**Critério de pronto:** `mgc auth` funciona e as variáveis estão carregadas no shell.

---

## Fase 1: Bootstrap do state remoto

Diretório: `infra/bootstrap/` (state **local**, que é o problema do ovo e da galinha).

1. **Limpar a tentativa anterior.** Existe um `terraform.tfstate` vazio e um `.terraform.tfstate.lock.info` deixado por um `plan` interrompido em 08/11. Confirme no console que o bucket `dataplat-state` **não** existe e apague o arquivo de lock.
2. **Revisar o provider em `main.tf`.** ✅ Feito: provider fixado em `~> 0.56.0`, com `key_pair_id`/`key_pair_secret` e `versioning` (sintaxe da 0.56).
3. Rodar:
   ```bash
   cd infra/bootstrap
   terraform init
   terraform plan
   terraform apply
   ```
4. Commitar `main.tf` e `.terraform.lock.hcl`. O state local do bootstrap deve ser guardado com cuidado fora do Git. Ele é pequeno e só contém o bucket.

**Critério de pronto:** o bucket `dataplat-state` existe com versionamento ativo. ✅ Concluído em 20/11/2026.

---

## Fase 2: Rede e cluster Kubernetes

Diretório: `infra/envs/dev/`, que compõe os módulos de `infra/modules/`.

### 2.1 Backend remoto

```hcl
terraform {
  backend "s3" {
    bucket = "dataplat-state"
    key    = "envs/dev/terraform.tfstate"
    region = "br-se1"
    endpoints = { s3 = "https://br-se1.magaluobjects.com" }
    use_path_style              = true
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
  }
}
```

### 2.2 Módulo `network`

- `mgc_network_vpcs` e `mgc_network_vpcs_subnets`.
- `mgc_network_security_groups` e `mgc_network_security_groups_rules`: liberar o MySQL **só para a rede do cluster** e o acesso administrativo **só para o seu IP**.

### 2.3 Módulo `kubernetes`

- `mgc_kubernetes_cluster` e `mgc_kubernetes_nodepool`.
- Dimensionamento inicial: 2 nós com 4 vCPU e 16 GB cada (⚠️ verificar os flavors disponíveis e o mínimo recomendado pelo Airbyte).
- Kubeconfig via data source `mgc_kubernetes_cluster_kubeconfig`, gravado em arquivo local `kubeconfig-dev` (ignorado pelo Git).

```bash
cd infra/envs/dev
terraform init && terraform apply
export KUBECONFIG=$PWD/kubeconfig-dev
kubectl get nodes
```

**Critério de pronto:** `kubectl get nodes` mostra os nós `Ready`.

---

## Fase 3: Banco de origem e bucket de destino

Ainda em `infra/envs/dev/`.

### 3.1 Módulo `database`: MySQL no DBaaS

- `mgc_dbaas_instances` com engine MySQL `8.4` (⚠️ verificar os engines e flavors disponíveis com `mgc dbaas engines list`).
- `mgc_dbaas_parameter_groups` e `mgc_dbaas_parameters` para **tentar** habilitar o CDC:
  - `binlog_format = ROW`
  - `binlog_row_image = FULL`
  - `binlog_expire_logs_seconds = 864000`
  - ⚠️ verificar se o DBaaS permite alterar esses parâmetros e criar um usuário com `REPLICATION SLAVE`. Se não permitir, isso já é um resultado do teste, e o CDC sai do escopo ou passa para um MySQL rodando no próprio cluster.
- A senha é gerada com `random_password` e exposta como output `sensitive`.

### 3.2 Módulo `storage`: bucket de destino

- `mgc_object_storage_buckets` com o nome `datavi-raw-dev`.
- O recurso não tem opção de destruição forçada (atributos: `bucket`, `cors`, `lock`, `policy`, `versioning`). Antes do teardown, o bucket precisa ser esvaziado.

**Critério de pronto:** é possível conectar no MySQL a partir de um pod do cluster, e o bucket existe.

---

## Fase 4: Carga do dataset público

### Dataset escolhido

**MySQL Employees Sample Database** (https://github.com/datacharmer/test_db):

- ~4 milhões de linhas em 6 tabelas, com chaves estrangeiras e datas. É um volume suficiente para medir throughput.
- Foi feito para MySQL, então carrega com um único `mysql < employees.sql`.
- Licença CC BY-SA.

Alternativa com dados brasileiros: **Olist Brazilian E-Commerce** (Kaggle, CSVs, ~100 mil pedidos). Exige login no Kaggle e um script de carga.

### Como carregar

Rodar um **Job no Kubernetes** (`k8s/bootstrap/load-dataset-job.yaml`) com imagem `mysql:8`. O Job clona o `test_db` e importa os dados no DBaaS. Assim o banco não precisa ficar exposto para a internet.

### Preparar para o teste incremental

Adicionar uma coluna `updated_at` (`TIMESTAMP ... ON UPDATE CURRENT_TIMESTAMP`) em pelo menos uma tabela, por exemplo `salaries`. Ela vai servir de cursor no modo incremental.

### Usuário do Airbyte

```sql
CREATE USER 'airbyte'@'%' IDENTIFIED BY '...';
GRANT SELECT, RELOAD, SHOW DATABASES, REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO 'airbyte'@'%';
-- Se o DBaaS não permitir os grants de replicação: apenas SELECT (modo STANDARD)
```

**Critério de pronto:** as contagens de linhas batem com as do `test_db`, rodando `SELECT COUNT(*)` nas 6 tabelas.

---

## Fase 5: Airbyte no cluster

Os manifests ficam em `k8s/values/airbyte.yaml`. A instalação usa o **chart v2**, porque o v1 não é mais suportado a partir do Airbyte 2.1:

```bash
helm repo add airbyte-v2 https://airbytehq.github.io/charts
helm repo update
kubectl create namespace airbyte
helm install airbyte airbyte-v2/airbyte \
  --namespace airbyte \
  --values k8s/values/airbyte.yaml \
  --version <versão fixa>
```

Decisões para a PoC:

- **Banco interno e storage de logs:** usar os padrões do chart (Postgres e MinIO dentro do cluster). Como tudo é destruído no fim, não precisamos de persistência externa.
- **Acesso:** sem Ingress e sem IP público. Acessar via `kubectl port-forward svc/airbyte-airbyte-server-svc 8000:8001 -n airbyte` (⚠️ verificar os nomes do service e das portas no chart instalado).
- Fixar a versão do chart em `values` e documentar essa versão aqui.

Depois da instalação:

1. Acessar a UI em `http://localhost:8000` e criar o usuário admin.
2. Em **Settings → Applications**, criar uma aplicação para obter o `client_id` e o `client_secret` que o Terraform vai usar.

Opcionalmente, a instalação do Helm pode virar Terraform com o provider `hashicorp/helm`. Isso permite subir tudo com um único `apply`.

**Critério de pronto:** todos os pods do namespace `airbyte` estão `Running` e a UI abre pelo port-forward.

---

## Fase 6: Fluxo do Airbyte como código

Diretório: `airbyte/`, uma configuração Terraform separada (state em `dataplat-state`, key `airbyte/terraform.tfstate`). Ela usa o provider `airbytehq/airbyte`:

```hcl
provider "airbyte" {
  server_url    = "http://localhost:8000/api/public/v1"  # via port-forward
  client_id     = var.airbyte_client_id
  client_secret = var.airbyte_client_secret
}
```

Recursos:

1. **Source MySQL:** host interno do DBaaS, database `employees` e usuário `airbyte`. Começar com o método `STANDARD`, depois testar `CDC`.
2. **Destination S3:**
   - `s3_endpoint = "https://br-se1.magaluobjects.com"`.
   - `s3_bucket_name = "datavi-raw-dev"`, `s3_bucket_path = "employees"`, `s3_bucket_region = "br-se1"`.
   - Formato Parquet (ou JSONL na primeira validação).
   - O conector força path-style desde a v1.9.2, o que é compatível com storage S3-like.
3. **Connection:** todas as tabelas do `employees`, com schedule manual na PoC.

**Critério de pronto:** `terraform apply` em `airbyte/` cria o fluxo, e ele aparece na UI.

---

## Fase 7: Testes de extração

Cada teste é registrado em `docs/resultados-poc.md` com duração, linhas, bytes, uso de CPU e memória dos pods, e problemas encontrados.

| # | Cenário | O que validar |
|---|---|---|
| 1 | **Full refresh** de todas as tabelas | Contagem no bucket = contagem no MySQL; tempo total; throughput |
| 2 | **Incremental por cursor** (`updated_at`) | Alterar N linhas → só N linhas novas no bucket |
| 3 | **CDC via binlog** (se o DBaaS permitir) | INSERT, UPDATE e DELETE capturados, com colunas `_ab_cdc_*` |
| 4 | **Mudança de schema** | Adicionar coluna → comportamento do schema propagation |
| 5 | **Falha e retomada** | Matar o pod do sync no meio → o retry funciona, sem duplicar ou perder dados |
| 6 | **Recriação do zero** | `destroy` + `apply` de tudo → o fluxo volta só com código |
| 7 | **Formato de saída** | Parquet legível (ex.: DuckDB lendo direto do bucket) |

Exemplo de validação com DuckDB:

```sql
SELECT COUNT(*) FROM read_parquet('s3://datavi-raw-dev/employees/salaries/*.parquet');
```

---

## Fase 8: Teardown

Ordem recomendada, sempre ao final de uma sessão de trabalho:

```bash
# 1. Fluxo do Airbyte (opcional: o cluster vai junto)
cd airbyte && terraform destroy

# 2. Esvaziar o bucket de destino (o provider não força a remoção)
mgc object-storage objects delete-all datavi-raw-dev   # ⚠️ verificar comando

# 3. Infra do ambiente
cd infra/envs/dev && terraform destroy
```

Depois, confira no console da MGC que não sobrou cluster, instância de DBaaS, IP público ou volume. O bucket `dataplat-state` **permanece**.

Para facilitar, vamos criar um `Makefile` com `make up` (fases 2 a 6) e `make down` (fase 8).

---

## Fase 9: Conclusão

Registrar um ADR em `docs/adr/0001-airbyte-como-ferramenta-de-extracao.md` com:

- O veredito: adotar, adotar com ressalvas ou descartar.
- Os números dos testes da fase 7.
- Limitações encontradas, por exemplo CDC no DBaaS, consumo de recursos e complexidade de operação.
- O custo aproximado do ambiente por hora ligado.
- Os próximos passos, caso o Airbyte seja adotado: Ingress com TLS, banco interno externo, CI/CD em `.github/workflows/`.

---

## Pendências a verificar

- [x] URL do endpoint S3 do Object Storage em `br-se1`: `https://br-se1.magaluobjects.com`.
- [ ] Se o DBaaS MySQL permite `binlog_format=ROW` via parameter group e grants de replicação.
- [ ] Flavors de nó do MKS e recursos mínimos recomendados para o Airbyte.
- [x] Se `mgc_object_storage_buckets` suporta destruir um bucket com objetos: não suporta.
- [ ] Nomes do service e das portas do `airbyte-server` no chart v2.
- [x] Separação correta das credenciais no `infra/bootstrap/main.tf` (API key × key pair do Object Storage).
