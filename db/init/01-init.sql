-- Jeu de données minimaliste mais réaliste pour la démonstration APM.
CREATE TABLE users (
    id          SERIAL PRIMARY KEY,
    email       TEXT NOT NULL UNIQUE,
    full_name   TEXT NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE products (
    id          SERIAL PRIMARY KEY,
    name        TEXT NOT NULL,
    price_fcfa  NUMERIC(10, 2) NOT NULL,
    stock       INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE orders (
    id          SERIAL PRIMARY KEY,
    user_id     INTEGER NOT NULL REFERENCES users(id),
    total_fcfa  NUMERIC(10, 2) NOT NULL,
    status      TEXT NOT NULL DEFAULT 'pending',
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE audit_log (
    id          SERIAL PRIMARY KEY,
    user_id     INTEGER,
    action      TEXT NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO users (email, full_name) VALUES
    ('alice.martin@example.com', 'Alice Martin'),
    ('bob.diallo@example.com', 'Bob Diallo'),
    ('carole.kossi@example.com', 'Carole Kossi'),
    ('david.sow@example.com', 'David Sow'),
    ('eva.dossou@example.com', 'Eva Dossou');

INSERT INTO products (name, price_fcfa, stock) VALUES
    ('Clavier mécanique', 59000, 25),
    ('Souris sans fil', 19500, 80),
    ('Écran 27 pouces', 165000, 12),
    ('Casque audio', 79000, 30),
    ('Station de charge USB-C', 30000, 60);

INSERT INTO audit_log (user_id, action) VALUES
    (1, 'account_created'),
    (2, 'login'),
    (3, 'order_created');
