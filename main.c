/* main.c (Executable entry point, and support library for Tally) */

#include <libintl.h>
#include <locale.h>
#include <lua.h>

#include <lualib.h>
#include <lauxlib.h>

/* The first macro quotes the argument name as a string. The second allows the passing of a macro value to be quoted instead. */
#define QUOTE(name) #name
#define MSTR(macro) QUOTE(macro)
/* Environment variables passed from the Makefile, whose values are made into C strings. */
#define APP_ID MSTR(PACKAGE)
#define APP_VER MSTR(VERSION)

static int
lua_get_is_devel(lua_State *L)
{
#ifdef DEVEL
	lua_pushboolean(L, 1);
#else
	lua_pushboolean(L, 0);
#endif
	return 1;
}

static int
lua_get_app_id(lua_State *L)
{
	lua_pushstring(L, APP_ID);
	return 1;
}

static int
lua_get_app_ver(lua_State *L)
{
	lua_pushstring(L, APP_VER);
	return 1;
}

static int
lua_gettext(lua_State *L)
{
	const char *msgid;
	char *msg;

	msgid = luaL_checkstring(L, 1);
	if (!msgid) {
		luaL_pushfail(L);
		return 1;
	}

	msg = gettext(msgid);
	lua_pushstring(L, msg);
	return 1;
}

/* Define a Lua function called lua_load_<name> which which returns the results from importing the given module. The same module can be imported from the Lua side as well by calling require("<name>"). The macro assumes that there is Lua bytecode named <name>.bytecode being linked to the main program. */
#define LUAMOD(name) \
	extern char _binary_##name##_bytecode_start[]; \
	extern char _binary_##name##_bytecode_end[]; \
	static int \
	lua_load_##name (lua_State *L) \
	{ \
		size_t len, stack_size; \
		int lua_result, num_returns; \
		len = ((size_t)_binary_##name##_bytecode_end) - \
			((size_t)_binary_##name##_bytecode_start); \
		lua_getglobal(L, "package"); \
		lua_getfield(L, -1, "loaded"); \
		lua_remove(L, -2); \
		lua_result = luaL_loadbuffer(L, \
			_binary_##name##_bytecode_start, \
			len, \
			QUOTE(name)); \
		if (lua_result != LUA_OK) \
			return 0; \
		lua_call(L, 0, 1); \
		lua_pushstring(L, QUOTE(name)); \
		lua_pushvalue(L, -2); \
		lua_settable(L, -4); \
		lua_remove(L, -3); \
		return 1; \
	}

LUAMOD(counter)

static const luaL_Reg mainlib[] = {
	{ "get_is_devel", lua_get_is_devel },
	{ "get_app_id", lua_get_app_id },
	{ "get_app_ver", lua_get_app_ver },
	{ "gettext", lua_gettext },
	{ "load_counter", lua_load_counter },
	{ NULL, NULL },
};

extern char _binary_main_bytecode_start[];
extern char _binary_main_bytecode_end[];

int
main()
{
	lua_State *L;
	size_t main_bytecode_len;
	int lua_result;

	/* This line is enough to tell Adwaita to be French. */
	setlocale(LC_ALL, "");
	/* Tells gettext where to look for messages files. Dest should be /app/share/locale/<lang>/LC_MESSAGES/<domain>.mo */
	bindtextdomain("messages", "/app/share/locale");
	textdomain("messages");

	/* Create a new Lua instance, and make the native C functions available through "mainlib". */
	L = luaL_newstate();
	luaL_openlibs(L);
	lua_getglobal(L, "package");
	lua_getfield(L, -1, "loaded");
	lua_remove(L, -2);
	lua_pushstring(L, "mainlib");
	luaL_newlib(L, mainlib);
	lua_settable(L, -3);
	lua_remove(L, -1);

	main_bytecode_len = ((size_t)_binary_main_bytecode_end) - ((size_t)_binary_main_bytecode_start);

	lua_result = luaL_loadbuffer(L, _binary_main_bytecode_start, main_bytecode_len, APP_ID);
	switch (lua_result) {
	case LUA_OK:
		lua_call(L, 0, 0);
		return 0;
	default:
		/* FIXME: Handle each error case individually. */
		fprintf(stderr, gettext("An unrecoverable error occurred when loading Tally, preventing the program from starting.\n"));
		return lua_result;
	}
}
