-- studio_db setup
CREATE TABLE IF NOT EXISTS tasks (
    id BIGSERIAL PRIMARY KEY,
    title VARCHAR(500) NOT NULL,
    description TEXT,
    status VARCHAR(50) NOT NULL DEFAULT 'backlog'
        CHECK (status IN ('backlog','maker','checker','arbitrage','done','failed')),
    maker_agent VARCHAR(100),
    checker_agent VARCHAR(100),
    maker_result TEXT,
    checker_verdict VARCHAR(20)
        CHECK (checker_verdict IS NULL OR checker_verdict IN ('PASS','FAIL','NEEDS_HUMAN')),
    session_id UUID DEFAULT gen_random_uuid(),
    created_at TIMESTAMP DEFAULT now(),
    updated_at TIMESTAMP DEFAULT now(),
    completed_at TIMESTAMP
);
CREATE TABLE IF NOT EXISTS projects (
    id BIGSERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    description TEXT,
    status VARCHAR(50) DEFAULT 'active'
        CHECK (status IN ('active','completed','archived')),
    repo_url VARCHAR(500),
    created_at TIMESTAMP DEFAULT now()
);
CREATE TABLE IF NOT EXISTS features (
    id BIGSERIAL PRIMARY KEY,
    title VARCHAR(500) NOT NULL,
    description TEXT,
    status VARCHAR(50) DEFAULT 'planned'
        CHECK (status IN ('planned','in_progress','done')),
    created_at TIMESTAMP DEFAULT now()
);
INSERT INTO projects (name, description, status) VALUES
    ('API Platform', 'REST API на FastAPI', 'active'),
    ('Agent Pipeline', 'Конвейер maker-checker-arbitrage', 'active');
INSERT INTO features (title, description, status) VALUES
    ('Maker-Checker Pipeline', 'Автоматический конвейер', 'in_progress'),
    ('RAG Knowledge Base', 'Семантический поиск', 'planned'),
    ('NocoDB Dashboard', 'Приборная панель', 'done');
INSERT INTO tasks (title, description, status, maker_agent, checker_agent) VALUES
    ('Создать API users CRUD', 'FastAPI CRUD users', 'backlog', 'python-dev', 'qa'),
    ('Написать тесты API users', 'Покрытие тестами', 'backlog', 'qa', 'qa'),
    ('Настроить CI/CD', 'GitHub Actions', 'backlog', 'backend-lead', 'loop-checker');
