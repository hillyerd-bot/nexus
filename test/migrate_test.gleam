//// Unit tests for the schema-script statement splitter in
//// `nexus/store/migrate`. The splitter must only split on top-level `;`,
//// ignoring semicolons inside quotes and comments — the trap for future
//// `DO $$ ... $$` blocks, `CREATE FUNCTION` bodies, and literals.

import gleeunit/should
import nexus/store/migrate

pub fn splits_top_level_semicolons_test() {
  migrate.statements("create table a (x int); create table b (y int);")
  |> should.equal(["create table a (x int)", "create table b (y int)"])
}

pub fn drops_empty_statements_test() {
  migrate.statements("") |> should.equal([])
  migrate.statements("   \n\t ") |> should.equal([])
  migrate.statements(";;;") |> should.equal([])
}

pub fn comment_only_input_test() {
  migrate.statements("-- just a comment\n-- and another\n")
  |> should.equal([])
}

pub fn semicolon_in_line_comment_test() {
  migrate.statements("select 1--a;b\nfrom t;select 2;")
  |> should.equal(["select 1\nfrom t", "select 2"])
}

pub fn semicolon_in_single_quoted_literal_test() {
  migrate.statements("insert into t values ('a;b');select 2;")
  |> should.equal(["insert into t values ('a;b')", "select 2"])
}

pub fn doubled_single_quote_is_escaped_test() {
  migrate.statements("select 'it''s;ok';select 2;")
  |> should.equal(["select 'it''s;ok'", "select 2"])
}

pub fn semicolon_in_double_quoted_identifier_test() {
  migrate.statements("select \"a;b\", \"c\"\"d;e\";select 2;")
  |> should.equal(["select \"a;b\", \"c\"\"d;e\"", "select 2"])
}

pub fn comment_markers_in_literal_are_literal_test() {
  migrate.statements("select '--';select '/*';select 2;")
  |> should.equal(["select '--'", "select '/*'", "select 2"])
}

pub fn semicolon_in_dollar_quote_test() {
  migrate.statements("do $$ begin; perform 1; end; $$;select 2;")
  |> should.equal(["do $$ begin; perform 1; end; $$", "select 2"])
}

pub fn semicolon_in_tagged_dollar_quote_test() {
  migrate.statements(
    "create function f() returns int as $fn$ begin; return 1; end; $fn$ language plpgsql;select 2;",
  )
  |> should.equal([
    "create function f() returns int as $fn$ begin; return 1; end; $fn$ language plpgsql",
    "select 2",
  ])
}

pub fn comment_markers_in_dollar_quote_are_literal_test() {
  migrate.statements("do $$ -- ; /* ; */ $$;select 2;")
  |> should.equal(["do $$ -- ; /* ; */ $$", "select 2"])
}

pub fn nested_different_dollar_tag_does_not_close_test() {
  migrate.statements("do $outer$ x $inner$ ; y $outer$;select 2;")
  |> should.equal(["do $outer$ x $inner$ ; y $outer$", "select 2"])
}

pub fn positional_parameter_is_not_a_dollar_quote_test() {
  migrate.statements("select $1;select $2;")
  |> should.equal(["select $1", "select $2"])
}

pub fn lone_dollar_is_literal_test() {
  migrate.statements("select 1 $ 2;select 3;")
  |> should.equal(["select 1 $ 2", "select 3"])
}

pub fn semicolon_in_block_comment_test() {
  migrate.statements("select/*a;b*/1;select 2;")
  |> should.equal(["select 1", "select 2"])
}

pub fn nested_block_comment_test() {
  migrate.statements("select/*a/*b;*/c;*/1;select 2;")
  |> should.equal(["select 1", "select 2"])
}

pub fn unterminated_dollar_quote_is_kept_test() {
  migrate.statements("do $$ begin; ")
  |> should.equal(["do $$ begin;"])
}
