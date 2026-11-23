BEGIN;

-- Define as duas direcoes contabeis possiveis de um lancamento: debito ou credito.
CREATE TYPE entry_direction as ENUM ('debit', 'credit');

-- 1. TABELA DE CONTAS (Onde o dinheiro fica agrupado)
-- Repare que NAO existe uma coluna "balance" (saldo) aqui! O saldo e calculado somando as entries.
CREATE TABLE accounts (
    id              uuid                PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Se for NULL, e uma conta interna do sistema/banco (ex: Cofre PIX, Taxas). Se tiver UUID, pertence a um usuario.
    owner_id        uuid,
    name            text                NOT NULL CHECK (name <> ''),
    -- Codigo ISO-4217 de 3 letras maiusculas (ex: 'BRL', 'USD', 'EUR').
    currency        text                NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
    -- Define se essa conta aumenta no 'debit' (ativos do banco) ou no 'credit' (passivos/carteira de clientes).
    normal_balance  entry_direction     NOT NULL,
    created_at      timestamptz         NOT NULL DEFAULT now(),

    -- Permite que a tabela 'entries' crie uma Foreign Key composta (id + currency),
    -- garantindo no proprio banco que voce nunca lance USD numa conta que e BRL!
    UNIQUE  (id, currency)
);

CREATE INDEX accounts_owner_id_idx ON accounts (owner_id);

-- 2. TABELA DE TRANSACOES (O cabecalho do evento financeiro)
-- Exemplo: "Transferencia PIX de Jorge para Maria". Ela agrupa as pernas (entries) da movimentacao.
CREATE TABLE transactions (
    id          uuid            PRIMARY KEY DEFAULT gen_random_uuid(),
    description text            NOT NULL,
    created_at  timestamptz     NOT NULL DEFAULT now()
);

-- 3. TABELA DE LANCAMENTOS / PARTIDAS (O coracao do Double-Entry Ledger)
-- Cada transacao tem pelo menos 2 linhas aqui: uma de 'debit' e uma de 'credit'.
CREATE TABLE entries (
    id              bigint              GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    transaction_id  uuid                NOT NULL REFERENCES transactions (id),
    account_id      uuid                NOT NULL,
    direction       entry_direction     NOT NULL,
    -- Sempre em centavos (int64 no Go) e SEMPRE positivo (> 0). Quem diz o sinal e a coluna 'direction'!
    amount          bigint              NOT NULL CHECK (amount > 0),
    currency        text                NOT NULL,
    created_at      timestamptz         NOT NULL DEFAULT now(),

    -- Garante que a moeda do lancamento e obrigatoriamente a mesma moeda da conta de destino!
    FOREIGN KEY (account_id, currency) REFERENCES accounts (id, currency)
);

CREATE INDEX entries_transaction_id_idx ON entries (transaction_id);
CREATE INDEX entries_account_id_idx ON entries (account_id);

-- 4. FUNCAO GUARDIA DO LIVRO-RAZAO (Garante que dinheiro nao surge do nada)
CREATE FUNCTION check_transaction_balanced() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE 
    tx_id uuid;
BEGIN
    -- Descobre qual e o ID da transacao dependendo de qual tabela disparou o gatilho:
    IF TG_TABLE_NAME = 'transactions' THEN
        tx_id := NEW.id;
    ELSE
        tx_id := NEW.transaction_id;
    END IF;

    -- Regra 1: Nao pode existir uma transacao "vazia" (sem nenhuma linha em entries).
    IF NOT EXISTS (SELECT 1 FROM entries WHERE transaction_id = tx_id) THEN
        RAISE EXCEPTION 'transaction % has no entries', tx_id
            USING ERRCODE = 'check_violation';
    END IF;

    -- Regra 2 (Partidas Dobradas): Soma todos os debitos (+amount) e subtrai todos os creditos (-amount)
    -- agrupados por moeda. Se o resultado for diferente de ZERO (<> 0), a transacao esta desbalanceada e o banco aborta!
    IF EXISTS (
        SELECT 1
        FROM entries
        WHERE transaction_id = tx_id
        GROUP BY currency
        HAVING sum(CASE direction WHEN 'debit' THEN amount ELSE -amount END) <> 0
    ) THEN
        RAISE EXCEPTION 'transaction % is not balanced', tx_id
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN NULL;
END;
$$;

-- 5. GATILHOS ADIADOS (DEFERRABLE INITIALLY DEFERRED)
-- Por que DEFERRED? Porque quando voce faz INSERT na tabela 'transactions', as 'entries' ainda nao foram inseridas!
-- Com INITIALLY DEFERRED, o Postgres espera voce fazer todos os INSERTs e so roda a checagem na hora do COMMIT final!
CREATE CONSTRAINT TRIGGER transaction_balanced
    AFTER INSERT ON transactions
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION check_transaction_balanced();

CREATE CONSTRAINT TRIGGER entries_balanced
    AFTER INSERT ON entries
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION check_transaction_balanced();



-- 6. PROTECAO DE IMUTABILIDADE (Append-Only)
-- Bloqueia qualquer tentativa de UPDATE ou DELETE nas tabelas financeiras.
-- Erros nunca sao apagados ou editados; devem ser corrigidos com uma nova transacao reversa (estorno).
CREATE FUNCTION forbid_ledger_changes() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION '% is append-only, post a reversing transaction instead', TG_TABLE_NAME
        USING ERRCODE = 'restrict_violation';
END;
$$;

CREATE TRIGGER transaction_append_only
    BEFORE UPDATE OR DELETE ON transactions
    FOR EACH ROW EXECUTE FUNCTION forbid_ledger_changes();

CREATE TRIGGER entries_append_only
    BEFORE UPDATE OR DELETE ON entries
    FOR EACH ROW EXECUTE FUNCTION forbid_ledger_changes();

-- 7. VIEW DE SALDOS (Calcula o saldo em tempo real a partir das entries)
-- Se a direcao da entry bater com o normal_balance da conta, soma (+amount); senao, subtrai (-amount).
-- O LEFT JOIN + coalesce garante que contas novas sem lancamentos retornem saldo 0 (e nao NULL).
CREATE VIEW account_balances AS 
SELECT
    a.id AS account_id,
    a.name,
    a.currency,
    coalesce(sum(
        CASE WHEN e.direction = a.normal_balance THEN e.amount ELSE -e.amount END
    ), 0)::bigint AS balance
FROM accounts a
LEFT JOIN entries e ON e.account_id = a.id
GROUP BY a.id;

COMMIT;