#!/usr/bin/env python3
"""v3 → v5 升级前置：给已存在的老表补上 init.sql 漏掉 ALTER 的列。

init.sql 对老库不是完全幂等的：新列只写在 CREATE TABLE IF NOT EXISTS 里，
老表已存在就被跳过，而后面引用这些列的索引会直接失败
（实测卡在 qd_strategy_trades / qd_strategy_positions 的 market_type）。

本脚本按 init.sql 的建表定义推导出缺失列的真实类型，生成并执行
ALTER TABLE ... ADD COLUMN IF NOT EXISTS。NOT NULL 且无默认值的列
会降级为可空，避免老数据行阻塞。

用法:
    python migrations/pre_v5_backfill_columns.py            # 只打印
    python migrations/pre_v5_backfill_columns.py --apply    # 实际执行
"""
import os
import re
import sys
import pathlib

import psycopg2

INIT_SQL = pathlib.Path(__file__).parent / "init.sql"


def parse_table_columns(sql: str) -> dict[str, dict[str, str]]:
    """表名 -> {列名: 该列的完整 DDL 片段}"""
    tables: dict[str, dict[str, str]] = {}
    for m in re.finditer(r"CREATE TABLE(?: IF NOT EXISTS)?\s+(\w+)\s*\((.*?)\n\);", sql, re.S):
        name, body = m.group(1), m.group(2)
        cols: dict[str, str] = {}
        depth = 0
        buf: list[str] = []
        for raw in body.splitlines():
            line = raw.strip()
            if not line or line.startswith("--"):
                continue
            buf.append(line)
            depth += line.count("(") - line.count(")")
            if depth > 0:
                continue
            stmt = " ".join(buf).rstrip(",")
            buf = []
            if re.match(r"^(PRIMARY|UNIQUE|FOREIGN|CONSTRAINT|CHECK)\b", stmt, re.I):
                continue
            cm = re.match(r'^"?(\w+)"?\s+(.+)$', stmt)
            if cm:
                cols[cm.group(1).lower()] = cm.group(2)
        tables.setdefault(name, {}).update(cols)
    return tables


def parse_altered(sql: str) -> dict[str, set[str]]:
    """init.sql 里已经显式 ALTER 补过的列，不需要我们插手"""
    out: dict[str, set[str]] = {}
    for m in re.finditer(r"ALTER TABLE (\w+) ADD COLUMN IF NOT EXISTS (\w+)", sql):
        out.setdefault(m.group(1), set()).add(m.group(2).lower())
    return out


def safe_ddl(ddl: str) -> str:
    """老表有数据，NOT NULL 又没默认值会失败，降级为可空。"""
    ddl = re.sub(r"--.*$", "", ddl).strip().rstrip(",").strip()
    has_default = re.search(r"\bDEFAULT\b", ddl, re.I)
    if re.search(r"\bNOT\s+NULL\b", ddl, re.I) and not has_default:
        ddl = re.sub(r"\s*\bNOT\s+NULL\b", "", ddl, flags=re.I)
    # 列级 REFERENCES 可能指向尚未建好的表，去掉；外键由 init.sql 自己补
    ddl = re.sub(r"\s*\bREFERENCES\b[^,]*$", "", ddl, flags=re.I)
    ddl = re.sub(r"\s*\bPRIMARY\s+KEY\b", "", ddl, flags=re.I)
    ddl = re.sub(r"\s*\bUNIQUE\b", "", ddl, flags=re.I)
    return ddl.strip()


def main() -> int:
    apply = "--apply" in sys.argv
    dsn = os.getenv("DATABASE_URL")
    if not dsn:
        env = pathlib.Path(__file__).parent.parent / ".env"
        if env.exists():
            m = re.search(r"^DATABASE_URL=(.*)$", env.read_text(), re.M)
            dsn = m.group(1).strip() if m else None
    if not dsn:
        print("缺少 DATABASE_URL", file=sys.stderr)
        return 2

    sql = INIT_SQL.read_text(encoding="utf-8")
    want = parse_table_columns(sql)
    altered = parse_altered(sql)

    conn = psycopg2.connect(dsn)
    conn.autocommit = False
    cur = conn.cursor()
    cur.execute("""select table_name, column_name from information_schema.columns
                   where table_schema='public'""")
    have: dict[str, set[str]] = {}
    for t, c in cur.fetchall():
        have.setdefault(t, set()).add(c.lower())

    stmts: list[tuple[str, str, str]] = []
    for table, cols in want.items():
        if table not in have:
            continue  # 新表交给 init.sql 建
        for col, ddl in cols.items():
            if col in have[table] or col in altered.get(table, set()):
                continue
            stmts.append((table, col, f'ALTER TABLE {table} ADD COLUMN IF NOT EXISTS "{col}" {safe_ddl(ddl)};'))

    print(f"需要补 {len(stmts)} 个列，涉及 {len({s[0] for s in stmts})} 张表\n")
    for table, col, s in stmts:
        print(f"  {s}")

    if not apply:
        print("\n（仅预览，加 --apply 才会执行）")
        return 0

    print()
    ok = 0
    for table, col, s in stmts:
        try:
            cur.execute(s)
            ok += 1
        except Exception as e:
            conn.rollback()
            print(f"  ✗ {table}.{col}: {e}")
            return 1
    conn.commit()
    print(f"  ✓ 成功补齐 {ok} 个列")
    return 0


if __name__ == "__main__":
    sys.exit(main())
