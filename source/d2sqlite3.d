// Written in the D programming language
/++
Simple SQLite interface.

This module provides a simple "object-oriented" interface to the SQLite
database engine.

Objects in this interface (Database and Query) automatically create the SQLite
objects they need. They are reference-counted, so that when their last
reference goes out of scope, the underlying SQLite objects are automatically
closed and finalized. They are not thread-safe.

Usage:
$(OL
    $(LI Create a Database object, providing the path of the database file (or
    an empty path, or the reserved path ":memory:").)
    $(LI Execute SQL code according to your need:
    $(UL
        $(LI If you don't need parameter binding, create a Query object with a
        single SQL statement and either use Query.execute() if you don't expect
        the query to return rows, or use Query.rows() directly in the other
        case.)
        $(LI If you need parameter binding, create a Query object with a
        single SQL statement that includes binding names, and use Parameter methods
        as many times as necessary to bind all values. Then either use
        Query.execute() if you don't expect the query to return rows, or use
        Query.rows() directly in the other case.)
        $(LI If you don't need parameter bindings and if you can ignore the
        rows that the query could return, you can use the facility function
        Database.execute(). In this case, more than one statements can be run
        in one call, as long as they are separated by semi-colons.)
    ))
)
See example in the documentation for the Database struct below.

Copyright:
    Copyright Nicolas Sicard, 2011-2014.

License:
    $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).

Authors:
    Nicolas Sicard (dransic@gmail.com).

Macros:
    D = <tt>$0</tt>
    DK = <strong><tt>$0</tt></strong>
+/
module d2sqlite3;

import std.conv;
import std.algorithm;
import std.exception;
import std.range;
import std.string;
import std.traits;
import std.typecons;
import std.typetuple;
import std.utf;
import std.variant;
import std.c.string : memcpy;
import etc.c.sqlite3;

/++
Metadata from the SQLite library.
+/
struct Sqlite3
{
    /++
    Gets the library's version string (e.g. 3.6.12).
    +/
    static @property string versionString()
    {
        return to!string(sqlite3_libversion());
    }
    
    /++
    Gets the library's version number (e.g. 3006012).
    +/
    static @property int versionNumber()
    {
        return sqlite3_libversion_number();
    }
}

static this()
{
    auto ver = Sqlite3.versionNumber;
    enforce(ver > 3003011, "Incompatible SQLite version: " ~ Sqlite3.versionString);
}

/++
Use of a shared cache.

See $(LINK http://www.sqlite.org/sharedcache.html)
+/
enum SharedCache : bool
{
    enabled = true, /// Shared cache is _enabled.
    disabled = false /// Shared cache is _disabled (the default in SQLite).
}

/++
An interface to a SQLite database connection.
+/
struct Database
{
    private
    {
        struct _Core
        {
            sqlite3* handle;
            
            this(sqlite3* handle)
            {
                this.handle = handle;
            }
            
            ~this()
            {
                auto result = sqlite3_close(handle);
                enforce(result == SQLITE_OK, new SqliteException(result));
            }
        }
        
        alias RefCounted!(_Core, RefCountedAutoInitialize.no) Core;
        Core core;
    }

    /++
    Opens a database connection.

    The path of the database file can be empty or set to ":memory:",
    according to the SQLite specification.
    +/
    this(string path, SharedCache sharedCache = SharedCache.disabled)
    {
        if (sharedCache)
        {
            auto result = sqlite3_enable_shared_cache(1);
            enforce(result == SQLITE_OK, new SqliteException(errorMsg, result));
        }
        sqlite3* hdl;
        auto result = sqlite3_open(cast(char*) path.toStringz(), &hdl);
        core = Core(hdl);
        enforce(result == SQLITE_OK && core.handle, new SqliteException(errorMsg, result));
    }

    unittest // Database construction
    {
        Database db1;
        auto db2 = db1;
        db1 = Database(":memory:");
        db2 = Database(":memory:");
        auto db3 = Database(":memory:");
        db1 = db2;
        assert(db2.core.refCountedStore.refCount == 2);
        assert(db1.core.refCountedStore.refCount == 2);
    }

    /++
    Execute the given SQL code.

    Rows returned by any statements are ignored.
    +/
    void execute(string sql)
    {
        char* errmsg;
        sqlite3_exec(core.handle, cast(char*) sql.toStringz(), null, null, &errmsg);
        if (errmsg !is null)
        {
            auto msg = to!string(errmsg);
            sqlite3_free(errmsg);
            throw new SqliteException(msg);
        }
    }
    
    unittest // Execute an SQL statement
    {
        auto db = Database(":memory:");
        db.execute(";");
    }
    
    /++
    Creates a _query on the database and returns it.
    +/
    Query query(string sql)
    {
        return Query(this, sql);
    }
    
    /++
    Gets the number of database rows that were changed, inserted or deleted by
    the most recently completed query.
    +/
    @property int changes()
    {
        return sqlite3_changes(core.handle);
    }

    /++
    Gets the number of database rows that were changed, inserted or deleted
    since the database was opened.
    +/
    @property int totalChanges()
    {
        return sqlite3_total_changes(core.handle);
    }

    /++
    Gets the SQLite error code of the last operation.
    +/
    @property int errorCode()
    {
        return sqlite3_errcode(core.handle);
    }
    
    /++
    Gets the SQLite error message of the last operation.
    +/
    @property string errorMsg()
    {
        return to!string(sqlite3_errmsg(core.handle));
    }

    /++
    Gets the SQLite internal _handle of the database connection.
    +/
    @property sqlite3* handle()
    {
        return core.handle;
    }

    /+
    Helper function to translate the arguments values of a D function
    into Sqlite values.
    +/
    private static @property string block_read_values(size_t n, string name, PT...)()
    {
        static if (n == 0)
            return null;
        else
        {
            enum index = n - 1;
            alias Unqual!(PT[index]) UT;
            static if (isBoolean!UT)
                enum templ = q{
                    @{previous_block}
                    type = sqlite3_value_numeric_type(argv[@{index}]);
                    enforce(type == SQLITE_INTEGER, new SqliteException(
                        "argument @{n} of function @{name}() should be a boolean"));
                    args[@{index}] = sqlite3_value_int64(argv[@{index}]) != 0;
                };
            else static if (isIntegral!UT)
                enum templ = q{
                    @{previous_block}
                    type = sqlite3_value_numeric_type(argv[@{index}]);
                    enforce(type == SQLITE_INTEGER, new SqliteException(
                        "argument @{n} of function @{name}() should be of an integral type"));
                    args[@{index}] = to!(PT[@{index}])(sqlite3_value_int64(argv[@{index}]));
                };
            else static if (isFloatingPoint!UT)
                enum templ = q{
                    @{previous_block}
                    type = sqlite3_value_numeric_type(argv[@{index}]);
                    enforce(type == SQLITE_FLOAT, new SqliteException(
                        "argument @{n} of function @{name}() should be a floating point"));
                    args[@{index}] = to!(PT[@{index}])(sqlite3_value_double(argv[@{index}]));
                };
            else static if (isSomeString!UT)
                enum templ = q{
                    @{previous_block}
                    type = sqlite3_value_type(argv[@{index}]);
                    enforce(type == SQLITE3_TEXT, new SqliteException(
                        "argument @{n} of function @{name}() should be a string"));
                    args[@{index}] = to!(PT[@{index}])(sqlite3_value_text(argv[@{index}]));
                };
            else static if (isArray!UT && is(Unqual!(ElementType!UT) : ubyte))
                enum templ = q{
                    @{previous_block}
                    type = sqlite3_value_type(argv[@{index}]);
                    enforce(type == SQLITE_BLOB, new SqliteException(
                        "argument @{n} of function @{name}() should be of an array of bytes (BLOB)"));
                    n = sqlite3_value_bytes(argv[@{index}]);
                    blob.length = n;
                    memcpy(blob.ptr, sqlite3_value_blob(argv[@{index}]), n);
                    args[@{index}] = to!(PT[@{index}])(blob.dup);
                };
            else
                static assert(false, PT[index].stringof ~ " is not a compatible argument type");

            return render(templ, [
                "previous_block": block_read_values!(n - 1, name, PT),
                "index":  to!string(index),
                "n": to!string(n),
                "name": name
            ]);
        }
    }

    /+
    Helper function to translate the return of a function into a Sqlite value.
    +/
    private static @property string block_return_result(RT...)()
    {
        static if (isIntegral!RT || isBoolean!RT)
            return q{
                auto result = to!long(tmp);
                sqlite3_result_int64(context, result);
            };
        else static if (isFloatingPoint!RT)
            return q{
                auto result = to!double(tmp);
                sqlite3_result_double(context, result);
            };
        else static if (isSomeString!RT)
            return q{
                auto result = to!string(tmp);
                if (result)
                    sqlite3_result_text(context, cast(char*) result.toStringz(), -1, null);
                else
                    sqlite3_result_null(context);
            };
        else static if (isArray!RT && is(Unqual!(ElementType!RT) == ubyte))
            return q{
                auto result = to!(ubyte[])(tmp);
                if (result)
                    sqlite3_result_blob(context, cast(void*) result.ptr, cast(int) result.length, null);
                else
                    sqlite3_result_null(context);
            };
        else
            static assert(false, RT.stringof ~ " is not a compatible return type");
    }

    /++
    Creates and registers a new aggregate function in the database.

    The type Aggregate must be a $(DK struct) that implements at least these
    two methods: $(D accumulate) and $(D result), and that must be default-constructible.

    See also: $(LINK http://www.sqlite.org/lang_aggfunc.html)
    +/
    void createAggregate(Aggregate, string name = Aggregate.stringof)()
    {
        static assert(is(Aggregate == struct), name ~ " shoud be a struct");
        static assert(is(typeof(Aggregate.accumulate) == function), name ~ " shoud define accumulate()");
        static assert(is(typeof(Aggregate.result) == function), name ~ " shoud define result()");

        alias staticMap!(Unqual, ParameterTypeTuple!(Aggregate.accumulate)) PT;
        alias ReturnType!(Aggregate.result) RT;

        enum x_step = q{
            extern(C) static void @{name}_step(sqlite3_context* context, int argc, sqlite3_value** argv)
            {
                Aggregate* agg = cast(Aggregate*) sqlite3_aggregate_context(context, Aggregate.sizeof);
                if (!agg)
                {
                    sqlite3_result_error_nomem(context);
                    return;
                }

                PT args;
                int type;
                @{blob}

                @{block_read_values}

                try
                {
                    agg.accumulate(args);
                }
                catch (Exception e)
                {
                    auto txt = "error in aggregate function @{name}(): " ~ e.msg;
                    sqlite3_result_error(context, cast(char*) txt.toStringz(), -1);
                }
            }
        };
        enum x_step_mix = render(x_step, [
            "name": name,
            "blob": staticIndexOf!(ubyte[], PT) >= 0 ? q{ubyte[] blob;} : "",
            "block_read_values": block_read_values!(PT.length, name, PT)
        ]);
        //pragma(msg, x_step_mix);
        mixin(x_step_mix);

        enum x_final = q{
            extern(C) static void @{name}_final(sqlite3_context* context)
            {
                Aggregate* agg = cast(Aggregate*) sqlite3_aggregate_context(context, Aggregate.sizeof);
                if (!agg)
                {
                    sqlite3_result_error_nomem(context);
                    return;
                }

                try
                {
                    auto tmp = agg.result();
                    mixin(block_return_result!RT);
                }
                catch (Exception e)
                {
                    auto txt = "error in aggregate function @{name}(): " ~ e.msg;
                    sqlite3_result_error(context, cast(char*) txt.toStringz(), -1);
                }
            }
        };
        enum x_final_mix = render(x_final, [
            "name": name
        ]);
        //pragma(msg, x_final_mix);
        mixin(x_final_mix);

        auto result = sqlite3_create_function(
            core.handle,
            name.toStringz(),
            PT.length,
            SQLITE_UTF8,
            null,
            null,
            mixin(format("&%s_step", name)),
            mixin(format("&%s_final", name))
        );
        enforce(result == SQLITE_OK, new SqliteException(errorMsg, result));
    }
    ///
    unittest // Aggregate creation
    {
        struct weighted_average
        {
            double total_value = 0.0;
            double total_weight = 0.0;

            void accumulate(double value, double weight)
            {
                total_value += value * weight;
                total_weight += weight;
            }

            double result()
            {
                return total_value / total_weight;
            }
        }

        auto db = Database(":memory:");
        db.execute("CREATE TABLE test (value FLOAT, weight FLOAT)");
        db.createAggregate!(weighted_average, "w_avg")();

        auto query = db.query("INSERT INTO test (value, weight) VALUES (:v, :w)");
        double[double] list = [11.5: 3, 14.8: 1.6, 19: 2.4];
        foreach (value, weight; list) {
            query.params.bind(":v", value).bind(":w", weight);
            query.execute();
            query.reset();
        }

        query = db.query("SELECT w_avg(value, weight) FROM test");
        import std.math: approxEqual;        
        assert(approxEqual(query.oneValue!double, (11.5*3 + 14.8*1.6 + 19*2.4)/(3 + 1.6 + 2.4)));
    }

    /++
    Creates and registers a collation function in the database.

    The function $(D_PARAM fun) must satisfy these criteria:
    $(UL
        $(LI It must two string arguments, e.g. s1 and s2.)
        $(LI Its return value $(D ret) must satisfy these criteria (when s3 is any other string):
            $(UL
                $(LI If s1 is less than s2, $(D ret < 0).)
                $(LI If s1 is equal to s2, $(D ret == 0).)
                $(LI If s1 is greater than s2, $(D ret > 0).)
                $(LI If s1 is equal to s2, then s2 is equal to s1.)
                $(LI If s1 is equal to s2 and s2 is equal to s3, then s1 is equal to s3.)
                $(LI If s1 is less than s2, then s2 is greater than s1.)
                $(LI If s1 is less than s2 and s2 is less than s3, then s1 is less than s3.)
            )
        )
    )

    The function will have the name $(D_PARAM name) in the database; this name defaults to
    the identifier of the function fun.

    See also: $(LINK http://www.sqlite.org/lang_aggfunc.html)
    +/
    void createCollation(alias fun, string name = __traits(identifier, fun))()
    {
        static assert(__traits(isStaticFunction, fun), "symbol " ~ __traits(identifier, fun)
                      ~ " of type " ~ typeof(fun).stringof ~ " is not a static function");

        alias ParameterTypeTuple!fun PT;
        static assert(isSomeString!(PT[0]), "the first argument of function " ~ name ~ " should be a string");
        static assert(isSomeString!(PT[1]), "the second argument of function " ~ name ~ " should be a string");
        static assert(isImplicitlyConvertible!(ReturnType!fun, int), "function " ~ name ~ " should return a value convertible to an integer");

        enum funpointer = &fun;
        enum x_compare = q{
            extern (C) static int @{name}(void*, int n1, const(void*) str1, int n2, const(void* )str2)
            {
                char[] s1, s2;
                s1.length = n1;
                s2.length = n2;
                memcpy(s1.ptr, str1, n1);
                memcpy(s2.ptr, str2, n2);
                return funpointer(cast(immutable) s1, cast(immutable) s2);
            }
        };
        mixin(render(x_compare, ["name": name]));

        auto result = sqlite3_create_collation(
            core.handle,
            name.toStringz(),
            SQLITE_UTF8,
            null,
            mixin("&" ~ name)
        );
        enforce(result == SQLITE_OK, new SqliteException(errorMsg, result));
    }
    ///
    unittest // Collation creation
    {
        static int my_collation(string s1, string s2)
        {
            import std.uni;
            return icmp(s1, s2);
        }

        auto db = Database(":memory:");
        db.createCollation!my_collation();
        db.execute("CREATE TABLE test (val TEXT)");

        auto query = db.query("INSERT INTO test (val) VALUES (:val)");
        query.params.bind(":val", "A");
        query.execute();
        query.reset();
        query.params.bind(":val", "B");
        query.execute();
        query.reset();
        query.params.bind(":val", "a");
        query.execute();

        query = db.query("SELECT val FROM test ORDER BY val COLLATE my_collation");
        assert(query.rows.front[0].get!string() == "A");
        query.rows.popFront();
        assert(query.rows.front[0].get!string() == "a");
        query.rows.popFront();
        assert(query.rows.front[0].get!string() == "B");
    }

    /++
    Creates and registers a simple function in the database.

    The function $(D_PARAM fun) must satisfy these criteria:
    $(UL
        $(LI It must not be a variadic.)
        $(LI Its arguments must all have a type that is compatible with SQLite types:
             boolean, integral, floating point, string, or array of bytes (BLOB types).)
        $(LI Its return value must also be of a compatible type.)
    )

    The function will have the name $(D_PARAM name) in the database; this name defaults to
    the identifier of the function fun.

    See also: $(LINK http://www.sqlite.org/lang_corefunc.html)
    +/
    void createFunction(alias fun, string name = __traits(identifier, fun))()
    {
        static if (__traits(isStaticFunction, fun))
            enum funpointer = &fun;
        else
            static assert(false, "symbol " ~ __traits(identifier, fun) ~ " of type "
                          ~ typeof(fun).stringof ~ " is not a static function");

        static assert(variadicFunctionStyle!(fun) == Variadic.no);

        alias staticMap!(Unqual, ParameterTypeTuple!fun) PT;
        alias ReturnType!fun RT;

        enum x_func = q{
            extern(C) static void @{name}(sqlite3_context* context, int argc, sqlite3_value** argv)
            {
                PT args;
                int type, n;
                @{blob}

                @{block_read_values}

                try
                {
                    auto tmp = funpointer(args);
                    mixin(block_return_result!RT);
                }
                catch (Exception e)
                {
                    auto txt = "error in function @{name}(): " ~ e.msg;
                    sqlite3_result_error(context, cast(char*) txt.toStringz(), -1);
                }
            }
        };
        enum x_func_mix = render(x_func, [
            "name": name,
            "blob": staticIndexOf!(ubyte[], PT) >= 0 ? q{ubyte[] blob;} : "",
            "block_read_values": block_read_values!(PT.length, name, PT)
        ]);
        //pragma(msg, x_step_mix);
        mixin(x_func_mix);

        auto result = sqlite3_create_function(
            core.handle,
            name.toStringz(),
            PT.length,
            SQLITE_UTF8,
            null,
            mixin(format("&%s", name)),
            null,
            null
        );
        enforce(result == SQLITE_OK, new SqliteException(errorMsg, result));
    }
    ///
    unittest // Function creation
    {
        static string test_args(bool b, int i, double d, string s, ubyte[] a)
        {
            if (b && i == 42 && d == 4.2 && s == "42" && a == [0x04, 0x02])
                return "OK";
            else
                return "NOT OK";
        }
        static bool test_bool()
        {
            return true;
        }
        static int test_int()
        {
            return 42;
        }
        static double test_double()
        {
            return 4.2;
        }
        static string test_string()
        {
            return "42";
        }
        static immutable(ubyte)[] test_ubyte()
        {
            return [0x04, 0x02];
        }

        auto db = Database(":memory:");
        db.createFunction!test_args();
        db.createFunction!test_bool();
        db.createFunction!test_int();
        db.createFunction!test_double();
        db.createFunction!test_string();
        db.createFunction!test_ubyte();
        auto query = db.query("SELECT test_args(test_bool(), test_int(), test_double(), test_string(), test_ubyte())");
        assert(query.rows.front[0].get!string() == "OK");
    }
}

///
unittest // Documentation example
{
    // Open a database in memory.
    Database db;
    try
    {
        db = Database(":memory:");
    }
    catch (SqliteException e)
    {
        // Error creating the database
        assert(false, "Error: " ~ e.msg);
    }
    
    // Create a table.
    try
    {
        db.execute(
            "CREATE TABLE person (
                id INTEGER PRIMARY KEY,
                last_name TEXT NOT NULL,
                first_name TEXT,
                score REAL,
                photo BLOB
             )"
        );
    }
    catch (SqliteException e)
    {
        // Error creating the table.
        assert(false, "Error: " ~ e.msg);
    }
    
    // Populate the table.
    try
    {
        auto query = db.query(
            "INSERT INTO person (last_name, first_name, score, photo)
             VALUES (:last_name, :first_name, :score, :photo)"
        );
        
        // Bind everything with chained calls to params.bind().
        query.params.bind(":last_name", "Smith")
                    .bind(":first_name", "John")
                    .bind(":score", 77.5);
        ubyte[] photo = cast(ubyte[]) "..."; // Store the photo as raw array of data.
        query.params.bind(":photo", photo);
        query.execute();
        
        query.reset(); // Need to reset the query after execution.
        query.params.bind(":last_name", "Doe")
                    .bind(":first_name", "John")
                    .bind(3, null) // Use of index instead of name.
                    .bind(":photo", null);
        query.execute();
    }
    catch (SqliteException e)
    {
        // Error executing the query.
        assert(false, "Error: " ~ e.msg);
    }
    assert(db.totalChanges == 2); // Two 'persons' were inserted.
    
    // Reading the table
    try
    {
        // Count the Johns in the table.
        auto query = db.query("SELECT count(*) FROM person WHERE first_name == 'John'");
        assert(query.rows.front[0].get!int() == 2);
        
        // Fetch the data from the table.
        query = db.query("SELECT * FROM person");
        foreach (row; query.rows)
        {
            // "id" should be the column at index 0:
            auto id = row[0].get!int();
            // Some conversions are possible with the method as():
            auto name = format("%s, %s", row["last_name"].get!string(), row["first_name"].get!(char[])());
            // The score can be NULL, so provide 0 (instead of NAN) as a default value to replace NULLs:
            auto score = row["score"].get!real(0.0);
            // Use of opDispatch with column name:
            auto photo = row.photo.get!(ubyte[])();
            
            // ... and use all these data!
        }
    }
    catch (SqliteException e)
    {
        // Error reading the database.
        assert(false, "Error: " ~ e.msg);
    }
}

/++
An interface to SQLite query execution.
+/
struct Query
{
    private
    {
        struct _Core
        {
            Database db;
            string sql;
            sqlite3_stmt* statement;
            Parameters params;
            RowSet rows;
            
            this(Database db, string sql, sqlite3_stmt* statement, Parameters params, RowSet rows)
            {
                this.db = db;
                this.sql = sql;
                this.statement = statement;
                this.params = params;
                this.rows = rows;
            }
            
            ~this()
            {
                auto result = sqlite3_finalize(statement);
                enforce(result == SQLITE_OK, new SqliteException(result));
            }
        }
        alias RefCounted!(_Core, RefCountedAutoInitialize.no) Core;
        Core core;
        
        @disable this();
        
        this(Database db, string sql)
        {
            sqlite3_stmt* statement;
            auto result = sqlite3_prepare_v2(
                db.core.handle,
                cast(char*) sql.toStringz(),
                cast(int) sql.length,
                &statement,
                null
                );
            enforce(result == SQLITE_OK, new SqliteException(db.errorMsg, result));
            core = Core(db, sql, statement, Parameters(statement), RowSet(&this));
        }
        
        unittest // Query construction
        {
            Database db = Database(":memory:");
            auto q1 = db.query("SELECT 42");
            assert(q1.statement);
            {
                auto q2 = q1;
                assert(q1.core.refCountedStore.refCount == 2);
                assert(q2.core.refCountedStore.refCount == 2);
            }
            assert(q1.core.refCountedStore.refCount == 1);
        }
    }

    /++
    Gets the bindable parameters of the query.

    The returned Parameters object becomes invalid when the Query goes out of scope.
    +/
    @property ref Parameters params()
    {
        return core.params;
    }

    /++
    Executes the query.

    Use rows() directly if the query is expected to return rows.
    +/
    void execute()
    {
        if (!core.rows.isInitialized)
        {
            core.rows = RowSet(&this);
            core.rows.initialize();
        }
    }
    
    /++
    Gets the results of a query that returns _rows.

    The returned RowSet object has a range interface. It becomes invalid
    when the Query goes out of scope.
    +/
    @property ref RowSet rows()
    {
        if (!core.rows.isInitialized)
        {
            core.rows = RowSet(&this);
            core.rows.initialize();
        }
        return core.rows;
    }

    unittest // Empty query
    {
        auto db = Database(":memory:");
        db.execute(";");
        auto query = db.query("-- This is a comment !");
        assert(query.rows.empty);
        assert(query.params.length == 0);
        query.params.clear();
        query.reset();
    }

    unittest // Query rows
    {
        // Query rows
        static assert(isInputRange!RowSet);
        auto db = Database(":memory:");
        db.execute("CREATE TABLE test (val INTEGER)");

        auto query = db.query("INSERT INTO test (val) VALUES (:val)");
        query.params.bind(":val", 42);
        query.execute();
        assert(query.rows.empty);
        query = db.query("SELECT * FROM test");
        assert(!query.rows.empty);
        assert(query.rows.front[0].get!int() == 42);
        query.rows.popFront();
        assert(query.rows.empty);
    }

    /++
    Gets only the first value of the first row returned by a query.
    +/
    @property auto oneValue(T)()
    {
        auto r = rows;
        if (!r.empty) {
            auto f = rows.front;
            if (f.columns.length)
                return f[0].get!T;
        }
        throw new SqliteException("No value available");
    }
    ///
    unittest // One value
    {
        auto db = Database(":memory:");
        db.execute("CREATE TABLE test (val INTEGER)");
        auto query = db.query("SELECT count(*) FROM test");
        query.execute();
        assert(query.oneValue!int == 0);
    }

    /++
    Resets a query's prepared statement before a new execution.

    This does not clear the bindings. Use Parameters.clear() for this.
    +/
    void reset()
    {
        if (core.statement)
        {
            auto result = sqlite3_reset(core.statement);
            enforce(result == SQLITE_OK, new SqliteException(core.db.errorMsg, result));
            core.rows = RowSet(&this);
        }
    }
    
    /++
    Gets the SQLite internal handle of the query _statement.
    +/
    @property sqlite3_stmt* statement()
    {
        return core.statement;
    }
}

/++
The bound parameters of a query.
+/
struct Parameters
{
    private sqlite3_stmt* statement;

    private this(sqlite3_stmt* statement)
    {
        this.statement = statement;
    }

    /++
    Binds values to parameters in the query.

    The index is the position of the parameter in the SQL query (starting from 0).
    The name must include the ':', '@' or '$' that introduces it in the query.
    +/
    ref Parameters bind(T)(int index, T value)
    {
        assert(statement);

        enforce(length > 0, new SqliteException("no parameter in prepared statement."));

        alias Unqual!T U;
        int result;

        static if (is(U == typeof(null)))
        {
            result = sqlite3_bind_null(statement, index);
        }
        else static if (is(U == void*))
        {
            result = sqlite3_bind_null(statement, index);
        }
        else static if (isIntegral!U && U.sizeof == int.sizeof)
        {
            result = sqlite3_bind_int(statement, index, value);
        }
        else static if (isIntegral!U && U.sizeof == long.sizeof)
        {
            result = sqlite3_bind_int64(statement, index, cast(long) value);
        }
        else static if (isImplicitlyConvertible!(U, double))
        {
            result = sqlite3_bind_double(statement, index, value);
        }
        else static if (isSomeString!U)
        {
            string utf8 = value.toUTF8();
            enforce(utf8.length <= int.max, new SqliteException("string too long"));
            result = sqlite3_bind_text(statement, index, cast(char*) utf8.toStringz(), cast(int) utf8.length, null);
        }
        else static if (isArray!U)
        {
            if (!value.length)
                result = sqlite3_bind_null(statement, index);
            else
            {
                auto bytes = cast(ubyte[]) value;
                enforce(bytes.length <= int.max, new SqliteException("array too long"));
                result = sqlite3_bind_blob(statement, index, cast(void*) bytes.ptr, cast(int) bytes.length, null);
            }
        }
        else
            static assert(false, "cannot bind a value of type " ~ U.stringof);

        enforce(result == SQLITE_OK, new SqliteException(result));

        return this;
    }

    /// Ditto
    ref Parameters bind(T)(string name, T value)
    {
        assert(statement);
        enforce(length > 0, new SqliteException("no parameter in prepared statement"));
        auto index = sqlite3_bind_parameter_index(statement, cast(char*) name.toStringz());
        enforce(index > 0, new SqliteException(format("parameter named '%s' cannot be bound", name)));
        return bind(index, value);
    }

    unittest // Simple parameters binding
    {
        auto db = Database(":memory:");
        db.execute("CREATE TABLE test (val INTEGER)");

        auto query = db.query("INSERT INTO test (val) VALUES (:val)");
        query.params.bind(":val", 42);
        query.execute();
        query.reset();
        query.params.bind(1, 42);
        query.execute();
        query.reset();
        query.params.bind(1, 42);
        query.execute();
        query.reset();
        query.params.bind(":val", 42);
        query.execute();

        query = db.query("SELECT * FROM test");
        foreach (row; query.rows)
            assert(row[0].get!int() == 42);
    }

    unittest // Multiple parameters binding
    {
        auto db = Database(":memory:");
        db.execute("CREATE TABLE test (i INTEGER, f FLOAT, t TEXT)");
        auto query = db.query("INSERT INTO test (i, f, t) VALUES (:i, @f, $t)");
        assert(query.params.length == 3);
        query.params.bind("$t", "TEXT")
                    .bind(":i", 42)
                    .bind("@f", 3.14);
        query.execute();
        query.reset();
        query.params.bind(3, "TEXT")
                    .bind(1, 42)
                    .bind(2, 3.14);
        query.execute();

        query = db.query("SELECT * FROM test");
        foreach (row; query.rows)
        {
            assert(row.columnCount == 3);
            assert(row["i"].get!int() == 42);
            assert(row["f"].get!double() == 3.14);
            assert(row["t"].get!string() == "TEXT");
        }
    }

    /++
    Gets the number of parameters.
    +/
    @property int length()
    {
        if (statement)
            return sqlite3_bind_parameter_count(statement);
        else
            return 0;
    }

    /++
    Clears the bindings.

    This does not reset the prepared statement. Use Query.reset() for this.
    +/
    void clear()
    {
        if (statement)
        {
            auto result = sqlite3_clear_bindings(statement);
            enforce(result == SQLITE_OK, new SqliteException(result));
        }
    }
}

/++
The results of a query that returns rows, with an InputRange interface.
+/
struct RowSet
{
    private Query* query;
    private int sqliteResult = SQLITE_DONE;
    private bool isInitialized = false;

    private this(Query* query)
    {
        assert(query);
        this.query = query;
    }

    private void initialize()
    {
        assert(query);
        if (query.statement)
        {
            // Try to fetch first row
            sqliteResult = sqlite3_step(query.statement);
            if (sqliteResult != SQLITE_ROW && sqliteResult != SQLITE_DONE)
            {
                query.reset(); // necessary to retrieve the error message.
                throw new SqliteException(query.core.db.errorMsg, sqliteResult);
            }
        }
        else
            sqliteResult = SQLITE_DONE; // No statement, so RowSet is empty;
        isInitialized = true;
    }

    /++
    Tests whether no more rows are available.
    +/
    @property bool empty()
    {
        assert(query);
        assert(isInitialized);
        return sqliteResult == SQLITE_DONE;
    }

    /++
    Gets the current row.
    +/
    @property Row front()
    {
        if (!empty)
        {
            Row row;
            auto colcount = sqlite3_column_count(query.statement);
            row.columns.length = colcount;
            foreach (i; 0 .. colcount)
            {
                /*
                    TODO The name obtained from sqlite3_column_name is that of
                    the query text. We should test first for the real name with
                    sqlite3_column_database_name or sqlite3_column_table_name.
                */
                auto name = to!string(sqlite3_column_name(query.statement, i));
                auto type = sqlite3_column_type(query.statement, i);
                final switch (type) {
                case SQLITE_INTEGER:
                    row.columns[i] = Column(i, name, Variant(sqlite3_column_int64(query.statement, i)));
                    break;

                case SQLITE_FLOAT:
                    row.columns[i] = Column(i, name, Variant(sqlite3_column_double(query.statement, i)));
                    break;

                case SQLITE3_TEXT:
                    auto str = to!string(sqlite3_column_text(query.statement, i));
                    row.columns[i] = Column(i, name, Variant(str));
                    break;

                case SQLITE_BLOB:
                    auto ptr = sqlite3_column_blob(query.statement, i);
                    auto length = sqlite3_column_bytes(query.statement, i);
                    ubyte[] blob;
                    blob.length = length;
                    memcpy(blob.ptr, ptr, length);
                    row.columns[i] = Column(i, name, Variant(blob));
                    break;

                case SQLITE_NULL:
                    row.columns[i] = Column(i, name, Variant.init);
                    break;
                }
            }
            return row;
        }
        else
            throw new SqliteException("no row available");
    }

    /++
    Jumps to the next row.
    +/
    void popFront()
    {
        if (!empty)
            sqliteResult = sqlite3_step(query.statement);
        else
            throw new SqliteException("no row available");
    }
    
    /++
    Gets list of all rows
    +/
    @property Row[] all()
    {
        auto rowlist = appender!(Row[]);

        while (!empty)
        {
            rowlist.put(front);
            popFront();
        }

        return rowlist.data;
    }
}

/++
A SQLite row.
+/
struct Row
{
    private Column[] columns;

    /++
    Gets the number of columns in this row.
    +/
    @property size_t columnCount()
    {
        return columns.length;
    }

    /++
    Gets the column at the given _index or for the given name.
    +/
    Column opIndex(size_t index)
    {
        enforce(index >= 0 && index < columns.length,
                new SqliteException(format("invalid column index: %d", index)));
        return columns[index];
    }

    /// ditto
    Column opIndex(string name)
    {
        auto f = filter!((Column c) { return c.name == name; })(columns);
        if (!f.empty)
            return f.front;
        else
            throw new SqliteException("invalid column name: " ~ name);
    }

    /// ditto
    @property Column opDispatch(string name)()
    {
        return opIndex(name);
    }
}

/++
A SQLite column.
+/
struct Column
{
    size_t index;
    string name;
    private Variant data;

    /++
    Gets the value of the column converted _to type T.
    If the value is NULL, it is replaced by defaultValue.
    +/
    T get(T)(T defaultValue = T.init)
    {
        alias Unqual!T U;
        if (data.hasValue)
        {
            static if (is(U == bool))
                return cast(T) data.coerce!long() != 0;
            else static if (isIntegral!U)
                return cast(T) std.conv.to!U(data.coerce!long());
            else static if (isFloatingPoint!U)
                return cast(T) std.conv.to!U(data.coerce!double());
            else static if (isSomeString!U)
            {
                auto result = cast(T) std.conv.to!U(data.coerce!string());
                return result ? result : defaultValue;
            }
            else static if (isArray!U)
            {
                alias A = ElementType!U;
                auto result = cast(U) data.get!(ubyte[]);
                return result ? result : defaultValue;
            }
            else
                static assert(false, "value cannot be converted to type " ~ T.stringof);
        }
        else
            return defaultValue;
    }
}

unittest // Getting a colums
{
    auto db = Database(":memory:");
    db.execute("CREATE TABLE test (val INTEGER)");

    auto query = db.query("INSERT INTO test (val) VALUES (:val)");
    query.params.bind(":val", 42);
    query.execute();

    query = db.query("SELECT val FROM test");
    with (query.rows)
    {
        assert(front[0].get!int() == 42);
        assert(front["val"].get!int() == 42);
        assert(front.val.get!int() == 42);
    }
}

unittest // Getting null values
{
    // NULL values

    auto db = Database(":memory:");
    db.execute("CREATE TABLE test (val INTEGER)");

    auto query = db.query("INSERT INTO test (val) VALUES (:val)");
    query.params.bind(":val", null);
    query.execute();

    query = db.query("SELECT * FROM test");
    assert(query.rows.front["val"].get!int(-42) == -42);
}

unittest // Getting integer values
{
    auto db = Database(":memory:");
    db.execute("CREATE TABLE test (val INTEGER)");

    auto query = db.query("INSERT INTO test (val) VALUES (:val)");
    query.params.bind(":val", 2);
    query.params.clear(); // Resets binding to NULL.
    query.execute();
    query.reset();
    query.params.bind(":val", 42L);
    query.execute();
    query.reset();
    query.params.bind(":val", 42U);
    query.execute();
    query.reset();
    query.params.bind(":val", 42UL);
    query.execute();
    query.reset();
    query.params.bind(":val", true);
    query.execute();
    query.reset();
    query.params.bind(":val", '\x2A');
    query.execute();
    query.reset();
    query.params.bind(":val", null);
    query.execute();

    query = db.query("SELECT * FROM test");
    foreach (row; query.rows)
        assert(row["val"].get!long(42) == 42 || row["val"].get!long() == 1);
}

unittest // Getting float values
{
    auto db = Database(":memory:");
    db.execute("CREATE TABLE test (val FLOAT)");

    auto query = db.query("INSERT INTO test (val) VALUES (:val)");
    query.params.bind(":val", 42.0F);
    query.execute();
    query.reset();
    query.params.bind(":val", 42.0);
    query.execute();
    query.reset();
    query.params.bind(":val", 42.0L);
    query.execute();
    query.reset();
    query.params.bind(":val", null);
    query.execute();

    query = db.query("SELECT * FROM test");
    foreach (row; query.rows)
        assert(row["val"].get!real(42.0) == 42.0);
}

unittest // Getting text values
{
    auto db = Database(":memory:");
    db.execute("CREATE TABLE test (val TEXT)");

    auto query = db.query("INSERT INTO test (val) VALUES (:val)");
    query.params.bind(":val", "I am a text.");
    query.execute();
    query.reset();
    query.params.bind(":val", null);
    query.execute();
    string str;
    query.reset();
    query.params.bind(":val", str);
    query.execute();

    query = db.query("SELECT * FROM test");
    assert(query.rows.front["val"].get!string("I am a text") == "I am a text.");
}

unittest // Getting blob values
{
    auto db = Database(":memory:");
    db.execute("CREATE TABLE test (val BLOB)");

    auto query = db.query("INSERT INTO test (val) VALUES (:val)");
    ubyte[] array = [1, 2, 3];
    query.params.bind(":val", array);
    query.execute();
    query.reset();
    query.params.bind(":val", cast(ubyte[]) []);
    query.execute();

    query = db.query("SELECT * FROM test");
    foreach (row; query.rows)
        assert(row["val"].get!(ubyte[])([1, 2, 3]) ==  [1, 2, 3]);
}

unittest // Getting more blob values
{
    auto db = Database(":memory:");
    db.execute("CREATE TABLE test (val BLOB)");

    auto query = db.query("INSERT INTO test (val) VALUES (:val)");
    double[] array = [1.1, 2.14, 3.162];
    query.params.bind(":val", array);
    query.execute();
    query.reset();
    query.params.bind(":val", cast(double[]) []);
    query.execute();

    query = db.query("SELECT * FROM test");
    foreach (row; query.rows)
        assert(row["val"].get!(double[])([1.1, 2.14, 3.162]) ==  [1.1, 2.14, 3.162]);
}


/++
Exception thrown when SQLite functions return an error.
+/
class SqliteException : Exception
{
    int code;

    //@safe pure nothrow 
    this(int code, string file = __FILE__, size_t line = __LINE__, Throwable next = null)
    {
        this.code = code;
        string msg;
        try
            msg = "error code %d".format(code);
        catch (Exception)
            msg = "unknown error";
        super(msg, file, line, next);
    }

    //@safe pure nothrow 
    this(string msg, int code = -1, string file = __FILE__, size_t line = __LINE__, Throwable next = null)
    {
        this.code = code;
        super(msg, file, line, next);
    }
}

// Compile-time rendering of code templates.
private string render(string templ, string[string] args)
{
    string markupStart = "@{";
    string markupEnd = "}";

    string result;
    auto str = templ;
    while (true)
    {
        auto p_start = std.string.indexOf(str, markupStart);
        if (p_start < 0)
        {
            result ~= str;
            break;
        }
        else
        {
            result ~= str[0 .. p_start];
            str = str[p_start + markupStart.length .. $];

            auto p_end = std.string.indexOf(str, markupEnd);
            if (p_end < 0)
                assert(false, "Tag misses ending }");
            auto key = strip(str[0 .. p_end]);

            auto value = key in args;
            if (!value)
                assert(false, "Key '" ~ key ~ "' has no associated value");
            result ~= *value;

            str = str[p_end + markupEnd.length .. $];
        }
    }

    return result;
}

unittest // Code templates
{
    enum tpl = q{
        string @{function_name}() {
            return "Hello world!";
        }
    };
    mixin(render(tpl, ["function_name": "hello_world"]));
    static assert(hello_world() == "Hello world!");
}

version(TestMain) {
    void main() {
    }
}
