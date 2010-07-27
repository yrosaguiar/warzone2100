/*
	This file is part of Warzone 2100.
	Copyright (C) 1999-2004  Eidos Interactive
	Copyright (C) 2005-2010  Warzone 2100 Project

	Warzone 2100 is free software; you can redistribute it and/or modify
	it under the terms of the GNU General Public License as published by
	the Free Software Foundation; either version 2 of the License, or
	(at your option) any later version.

	Warzone 2100 is distributed in the hope that it will be useful,
	but WITHOUT ANY WARRANTY; without even the implied warranty of
	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
	GNU General Public License for more details.

	You should have received a copy of the GNU General Public License
	along with Warzone 2100; if not, write to the Free Software
	Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301 USA
*/
%{
/*
 * script.y
 *
 * The yacc grammar for the scipt files.
 */

#include "lib/framework/frame.h"
#include "lib/framework/frameresource.h"
#include "lib/framework/string_ext.h"
#include "lib/script/interpreter.h"
#include "lib/script/parse.h"
#include "lib/script/script.h"

#include <physfs.h>

/* this will give us a more detailed error output */
#define YYERROR_VERBOSE true

/* Script defines stack */

extern int scr_lex(void);
extern int scr_lex_destroy(void);

/* Error return codes for code generation functions */
typedef enum _code_error
{
	CE_OK,				// No error
	CE_MEMORY,			// Out of memory
	CE_PARSE			// A parse error occured
} CODE_ERROR;

/* Turn off a couple of warnings that the yacc generated code gives */

/* Pointer to the compiled code */
static SCRIPT_CODE	*psFinalProg=NULL;

/* Pointer to current block of compiled code */
static CODE_BLOCK	*psCurrBlock=NULL;

/* Pointer to current block of conditional code */
static COND_BLOCK	*psCondBlock=NULL;

/* Pointer to current block of object variable code */
static OBJVAR_BLOCK	*psObjVarBlock=NULL;

/* Pointer to current block of compiled parameter code */
static PARAM_BLOCK	*psCurrPBlock=NULL;

/* Any errors occured? */
static BOOL bError=false;

//String support
//-----------------------------
char 				msg[MAXSTRLEN];
extern char			STRSTACK[MAXSTACKLEN][MAXSTRLEN];	// just a simple string "stack"
extern UDWORD		CURSTACKSTR;				//Current string index

/* Pointer into the current code block */
static INTERP_VAL		*ip;

/* Pointer to current parameter declaration block */
//static PARAM_DECL	*psCurrParamDecl=NULL;

/* Pointer to current trigger subdeclaration */
static TRIGGER_DECL	*psCurrTDecl=NULL;

/* Pointer to current variable subdeclaration */
static VAR_DECL		*psCurrVDecl=NULL;

/* Pointer to the current variable identifier declaration */
static VAR_IDENT_DECL	*psCurrVIdentDecl=NULL;

/* Pointer to the current array access block */
static ARRAY_BLOCK		*psCurrArrayBlock=NULL;

/* Return code from code generation functions */
static CODE_ERROR	codeRet;

/* The list of global variables */
static VAR_SYMBOL	*psGlobalVars=NULL;

/* The list of global arrays */
static VAR_SYMBOL	*psGlobalArrays=NULL;

#define			maxEventsLocalVars		1200
static VAR_SYMBOL	*psLocalVarsB[maxEventsLocalVars];	/* local var storage */
static UDWORD		numEventLocalVars[maxEventsLocalVars];	/* number of declard local vars for each event */
EVENT_SYMBOL		*psCurEvent = NULL;		/* stores current event: for local var declaration */

/* The current object variable context */
static INTERP_TYPE	objVarContext = (INTERP_TYPE)0;

/* Control whether debug info is generated */
static BOOL			genDebugInfo = true;

/* Currently defined triggers */
static TRIGGER_SYMBOL	*psTriggers;
static UDWORD			numTriggers;

/* Currently defined events */
static EVENT_SYMBOL		*psEvents;
static UDWORD			numEvents;

/* This is true when local variables are being defined.
 * (So local variables can have the same name as global ones)
 */
static BOOL localVariableDef=false;

/* The identifier for the current script function being defined */
//static char *pCurrFuncIdent=NULL;

/* A temporary store for a line number - used when
 * generating debugging info for functions, conditionals and loops.
 */
static UDWORD		debugLine;

/* The table of user types */
TYPE_SYMBOL		*asScrTypeTab;

/* The table of instinct function type definitions */
FUNC_SYMBOL		*asScrInstinctTab;

/* The table of external variables and their access functions */
VAR_SYMBOL		*asScrExternalTab;

/* The table of object variables and their access functions. */
VAR_SYMBOL		*asScrObjectVarTab;

/* The table of constant variables */
CONST_SYMBOL	*asScrConstantTab;

/* The table of callback triggers */
CALLBACK_SYMBOL	*asScrCallbackTab;

/* Used for additional debug output */
void script_debug(const char *pFormat, ...);

/****************************************************************************************
 *
 * Code Block Macros
 *
 * These macros are used to allocate and free the different types of code
 * block used within the compiler
 */


/* What the macro should do if it has an allocation error.
 * This is different depending on whether the macro is used
 * in a function, or in a rule body.
 *
 * This definition is used within the code generation functions
 * and is then changed for use within a rule body.
 */
#define ALLOC_ERROR_ACTION return CE_MEMORY

/* Macro to allocate a program structure, size is in _bytes_ */
#define ALLOC_PROG(psProg, codeSize, pAICode, numGlobs, numArys, numTrigs, numEvnts) \
	(psProg) = (SCRIPT_CODE *)malloc(sizeof(SCRIPT_CODE)); \
	if ((psProg) == NULL) \
	{ \
		debug(LOG_ERROR, "Out of memory"); \
		ALLOC_ERROR_ACTION; \
	} \
	(psProg)->pCode = (INTERP_VAL *)malloc((codeSize) * sizeof(INTERP_VAL)); \
	if ((psProg)->pCode == NULL) \
	{ \
		debug(LOG_ERROR, "Out of memory"); \
		ALLOC_ERROR_ACTION; \
	} \
	if (numGlobs > 0) \
	{ \
		(psProg)->pGlobals = (INTERP_TYPE *)malloc(sizeof(INTERP_TYPE) * (numGlobs)); \
		if ((psProg)->pGlobals == NULL) \
		{ \
			debug(LOG_ERROR, "Out of memory"); \
			ALLOC_ERROR_ACTION; \
		} \
	} \
	else \
	{ \
		(psProg)->pGlobals = NULL; \
	} \
	if (numArys > 0) \
	{ \
		(psProg)->psArrayInfo = (ARRAY_DATA *)malloc(sizeof(ARRAY_DATA) * (numArys)); \
		if ((psProg)->psArrayInfo == NULL) \
		{ \
			debug(LOG_ERROR, "Out of memory"); \
			ALLOC_ERROR_ACTION; \
		} \
	} \
	else \
	{ \
		(psProg)->psArrayInfo = NULL; \
	} \
	(psProg)->numArrays = (UWORD)(numArys); \
	if ((numTrigs) > 0) \
	{ \
		(psProg)->pTriggerTab = malloc(sizeof(UWORD) * ((numTrigs) + 1)); \
		if ((psProg)->pTriggerTab == NULL) \
		{ \
			debug(LOG_ERROR, "Out of memory"); \
			ALLOC_ERROR_ACTION; \
		} \
		(psProg)->psTriggerData = malloc(sizeof(TRIGGER_DATA) * (numTrigs)); \
		if ((psProg)->psTriggerData == NULL) \
		{ \
			debug(LOG_ERROR, "Out of memory"); \
			ALLOC_ERROR_ACTION; \
		} \
	} \
	else \
	{ \
		(psProg)->pTriggerTab = NULL; \
		(psProg)->psTriggerData = NULL; \
	} \
	(psProg)->pEventTab = malloc(sizeof(UWORD) * ((numEvnts) + 1)); \
	if ((psProg)->pEventTab == NULL) \
	{ \
		debug(LOG_ERROR, "Out of memory"); \
		ALLOC_ERROR_ACTION; \
	} \
	(psProg)->pEventLinks = malloc(sizeof(SWORD) * (numEvnts)); \
	if ((psProg)->pEventLinks == NULL) \
	{ \
		debug(LOG_ERROR, "Out of memory"); \
		ALLOC_ERROR_ACTION; \
	} \
	(psProg)->numGlobals = (UWORD)(numGlobs); \
	(psProg)->numTriggers = (UWORD)(numTriggers); \
	(psProg)->numEvents = (UWORD)(numEvnts); \
	(psProg)->size = (codeSize) * sizeof(INTERP_VAL);

/* Macro to allocate a code block, blockSize - number of INTERP_VALs we need*/
#define ALLOC_BLOCK(psBlock, num) \
	(psBlock) = (CODE_BLOCK *)malloc(sizeof(CODE_BLOCK)); \
	if ((psBlock) == NULL) \
	{ \
		debug(LOG_ERROR, "Out of memory"); \
		ALLOC_ERROR_ACTION; \
	} \
	(psBlock)->pCode = (INTERP_VAL *)malloc((num) * sizeof(INTERP_VAL)); \
	if ((psBlock)->pCode == NULL) \
	{ \
		debug(LOG_ERROR, "Out of memory"); \
		free((psBlock)); \
		ALLOC_ERROR_ACTION; \
	} \
	(psBlock)->size = (num); \
	(psBlock)->debugEntries = 0

/* Macro to free a code block */
#define FREE_BLOCK(psBlock) \
	free((psBlock)->pCode); \
	free((psBlock))

/* Macro to allocate a parameter block */
#define ALLOC_PBLOCK(psBlock, num, paramSize) \
	(psBlock) = (PARAM_BLOCK *)malloc(sizeof(PARAM_BLOCK)); \
	if ((psBlock) == NULL) \
	{ \
		debug(LOG_ERROR, "Out of memory"); \
		ALLOC_ERROR_ACTION; \
	} \
	(psBlock)->pCode = (INTERP_VAL *)malloc((num) * sizeof(INTERP_VAL)); \
	if ((psBlock)->pCode == NULL) \
	{ \
		debug(LOG_ERROR, "Out of memory"); \
		free((psBlock)); \
		ALLOC_ERROR_ACTION; \
	} \
	(psBlock)->aParams = (INTERP_TYPE *)malloc(sizeof(INTERP_TYPE) * (paramSize)); \
	if ((psBlock)->aParams == NULL) \
	{ \
		debug(LOG_ERROR, "Out of memory"); \
		free((psBlock)->pCode); \
		free((psBlock)); \
		ALLOC_ERROR_ACTION; \
	} \
	(psBlock)->size = (num); \
	(psBlock)->numParams = (paramSize)

/* Macro to free a parameter block */
#define FREE_PBLOCK(psBlock) \
	free((psBlock)->pCode); \
	free((psBlock)->aParams); \
	free((psBlock))

/* Macro to allocate a parameter declaration block */
#define ALLOC_PARAMDECL(psPDecl, num) \
	(psPDecl) = (PARAM_DECL *)malloc(sizeof(PARAM_DECL)); \
	if ((psPDecl) == NULL) \
	{ \
		debug(LOG_ERROR, "Out of memory"); \
		ALLOC_ERROR_ACTION; \
	} \
	(psPDecl)->aParams = (INTERP_TYPE *)malloc(sizeof(INTERP_TYPE) * (num)); \
	if ((psPDecl)->aParams == NULL) \
	{ \
		debug(LOG_ERROR, "Out of memory"); \
		ALLOC_ERROR_ACTION; \
	} \
	(psPDecl)->numParams = (num)

/* Macro to free a parameter declaration block */
#define FREE_PARAMDECL(psPDecl) \
	free((psPDecl)->aParams); \
	free((psPDecl))

/* Macro to allocate a conditional block */
#define ALLOC_CONDBLOCK(psCB, num, numBlocks) \
	(psCB) = (COND_BLOCK *)malloc(sizeof(COND_BLOCK)); \
	if ((psCB) == NULL) \
	{ \
		debug(LOG_ERROR, "Out of memory"); \
		ALLOC_ERROR_ACTION; \
	} \
	(psCB)->aOffsets = (UDWORD *)malloc(sizeof(SDWORD) * (num)); \
	if ((psCB)->aOffsets == NULL) \
	{ \
		debug(LOG_ERROR, "Out of memory"); \
		ALLOC_ERROR_ACTION; \
	} \
	(psCB)->pCode = (INTERP_VAL *)malloc((numBlocks) * sizeof(INTERP_VAL)); \
	if ((psCB)->pCode == NULL) \
	{ \
		debug(LOG_ERROR, "Out of memory"); \
		ALLOC_ERROR_ACTION; \
	} \
	(psCB)->size = (numBlocks); \
	(psCB)->numOffsets = (num)

/* Macro to free a conditional block */
#define FREE_CONDBLOCK(psCB) \
	free((psCB)->aOffsets); \
	free((psCB)->pCode); \
	free(psCB)

/* Macro to free a code block */
#define FREE_USERBLOCK(psBlock) \
	free((psBlock)->pCode); \
	free((psBlock))

/* Macro to allocate an object variable block */
#define ALLOC_OBJVARBLOCK(psOV, blockSize, psVar) \
	(psOV) = (OBJVAR_BLOCK *)malloc(sizeof(OBJVAR_BLOCK)); \
	if ((psOV) == NULL) \
	{ \
		scr_error("Out of memory"); \
		ALLOC_ERROR_ACTION; \
	} \
	(psOV)->pCode = (INTERP_VAL *)malloc((blockSize) * sizeof(INTERP_VAL)); \
	if ((psOV)->pCode == NULL) \
	{ \
		scr_error("Out of memory"); \
		ALLOC_ERROR_ACTION; \
	} \
	(psOV)->size = (blockSize); \
	(psOV)->psObjVar = (psVar)

/* Macro to free an object variable block */
#define FREE_OBJVARBLOCK(psOV) \
	free((psOV)->pCode); \
	free(psOV)

/* Macro to allocate an array variable block */
#define ALLOC_ARRAYBLOCK(psAV, blockSize, psVar) \
	(psAV) = (ARRAY_BLOCK *)malloc(sizeof(ARRAY_BLOCK)); \
	if ((psAV) == NULL) \
	{ \
		scr_error("Out of memory"); \
		ALLOC_ERROR_ACTION; \
	} \
	(psAV)->pCode = (INTERP_VAL *)malloc((blockSize) * sizeof(INTERP_VAL)); \
	if ((psAV)->pCode == NULL) \
	{ \
		scr_error("Out of memory"); \
		ALLOC_ERROR_ACTION; \
	} \
	(psAV)->size = (blockSize); \
	(psAV)->dimensions = 1; \
	(psAV)->psArrayVar = (psVar)

/* Macro to free an object variable block */
#define FREE_ARRAYBLOCK(psAV) \
	free((psAV)->pCode); \
	free((psAV))

/* Allocate a trigger subdecl */
#define ALLOC_TSUBDECL(psTSub, blockType, blockSize, blockTime) \
	(psTSub) = malloc(sizeof(TRIGGER_DECL)); \
	if ((psTSub) == NULL) \
	{ \
		scr_error("Out of memory"); \
		ALLOC_ERROR_ACTION; \
	} \
	(psTSub)->type = (blockType); \
	(psTSub)->time = (blockTime); \
	if ((blockSize) > 0) \
	{ \
		(psTSub)->pCode = (INTERP_VAL *)malloc((blockSize) * sizeof(INTERP_VAL)); \
		if ((psTSub)->pCode == NULL) \
		{ \
			scr_error("Out of memory"); \
			ALLOC_ERROR_ACTION; \
		} \
		(psTSub)->size = (blockSize); \
	} \
	else \
	{ \
		(psTSub)->pCode = NULL; \
		(psTSub)->size = 0; \
	}

/* Free a trigger subdecl */
#define FREE_TSUBDECL(psTSub) \
	if ((psTSub)->pCode) \
	{ \
		free((psTSub)->pCode); \
	} \
	free(psTSub)

/* Allocate a variable declaration block */
#define ALLOC_VARDECL(psDcl) \
	(psDcl)=malloc(sizeof(VAR_DECL)); \
	if ((psDcl) == NULL) \
	{ \
		scr_error("Out of memory"); \
		ALLOC_ERROR_ACTION; \
	}

/* Free a variable declaration block */
#define FREE_VARDECL(psDcl) \
	free(psDcl)

/* Allocate a variable declaration block */
static inline CODE_ERROR do_ALLOC_VARIDENTDECL(VAR_IDENT_DECL** psDcl, const char* ident, unsigned int dim)
{
	// Allocate memory
	*psDcl = malloc(sizeof(VAR_IDENT_DECL));
	if (*psDcl == NULL)
	{
		scr_error("Out of memory");
		ALLOC_ERROR_ACTION;
	}

	// Copy over the "ident" string (if it's there)
	if (ident != NULL)
	{
		(*psDcl)->pIdent = strdup(ident);
		if ((*psDcl)->pIdent == NULL)
		{
			scr_error("Out of memory");
			ALLOC_ERROR_ACTION;
		}
	}
	else
	{
		(*psDcl)->pIdent = NULL;
	}

	(*psDcl)->dimensions = dim;

	return CE_OK;
}

#define ALLOC_VARIDENTDECL(psDcl, ident, dim) \
{ \
	CODE_ERROR err = do_ALLOC_VARIDENTDECL(&psDcl, ident, dim); \
	if (err != CE_OK) \
		return err; \
}

/* Free a variable declaration block */
static void freeVARIDENTDECL(VAR_IDENT_DECL* psDcl)
{
	free(psDcl->pIdent);
	free(psDcl);
}

/****************************************************************************************
 *
 * Code block manipulation macros.
 *
 * These are used to copy chunks of code from one block to another
 * or to insert opcodes or other values into a code block.
 * All the macros use the ip parameter.  This is a pointer into the code
 * block that is incremented by the macro. This ensures that it always points
 * to the next free space in the code block.
 */

/* Macro to store an opcode in a code block, opcode type is '-1' */
#define PUT_OPCODE(ip, opcode) \
	(ip)->type = VAL_OPCODE; \
	(ip)->v.ival = (opcode) << OPCODE_SHIFT; \
	(ip)++

/* Macro to put a packed opcode in a code block */
#define PUT_PKOPCODE(ip, opcode, data) \
	(ip)->type = VAL_PKOPCODE; \
	(ip)->v.ival = ((SDWORD)(data)) & OPCODE_DATAMASK; \
	(ip)->v.ival = (((SDWORD)(opcode)) << OPCODE_SHIFT) | ((ip)->v.ival); \
	(ip)++

/* Special macro for floats, could be a bit tricky */
#define PUT_DATA_FLOAT(ip, data) \
	ip->type = VAL_FLOAT; \
	ip->v.fval = (float)(data); \
	ip++

/* Macros to store a value in a code block */
#define PUT_DATA_BOOL(ip, value) \
	(ip)->type = VAL_BOOL; \
	(ip)->v.bval = (BOOL)(value); \
	(ip)++

#define PUT_DATA_INT(ip, value) \
	(ip)->type = VAL_INT; \
	(ip)->v.ival = (SDWORD)(value); \
	(ip)++

#define PUT_DATA_STRING(ip, value) \
	(ip)->type = VAL_STRING; \
	(ip)->v.sval = (char *)(value); \
	(ip)++

#define PUT_OBJECT_CONST(ip, value, constType) \
	(ip)->type = (constType); \
	(ip)->v.oval = (value); \
	(ip)++

#define PUT_STRING(ip, value) \
	((INTERP_VAL *)(ip))->type = VAL_STRING; \
	((INTERP_VAL *)(ip))->v.sval = (value); \
	((INTERP_VAL *)(ip)) += 1

/* Macro to store an external function index in a code block */
#define PUT_FUNC_EXTERN(ip, func) \
	(ip)->type = VAL_FUNC_EXTERN; \
	(ip)->v.pFuncExtern = (SCRIPT_FUNC)func; \
	(ip)++

/* Macro to store an internal (in-script, actually an event) function index in a code block */
#define PUT_EVENT(ip, func) \
	(ip)->type = VAL_EVENT; \
	(ip)->v.ival = (SDWORD)func; \
	(ip)++

/* Macro to store trigger */
#define PUT_TRIGGER(ip, func) \
	(ip)->type = VAL_TRIGGER; \
	(ip)->v.ival = (SDWORD)func; \
	(ip)++

/* Macro to store a function pointer in a code block */
#define PUT_VARFUNC(ip, func) \
	(ip)->type = VAL_OBJ_GETSET; \
	(ip)->v.pObjGetSet = (SCRIPT_VARFUNC)func; \
	(ip)++

/* Macro to store a variable index number in a code block - NOT USED */
#define PUT_INDEX(ip, index) \
	(ip)->type = -1; \
	(ip)->v.ival = (SDWORD)(index); \
	(ip)++

/* Macro to copy a code block into another code block */
#define PUT_BLOCK(ip, psOldBlock) \
	memcpy(ip, (psOldBlock)->pCode, (psOldBlock)->size * sizeof(INTERP_VAL)); \
	(ip) = (INTERP_VAL *)( (ip) + (psOldBlock)->size)

/***********************************************************************************
 *
 * Debugging information macros
 *
 * These macros are only used to generate debugging information for scripts.
 */

/* Macro to allocate debugging info for a CODE_BLOCK or a COND_BLOCK */
#define ALLOC_DEBUG(psBlock, num) \
	if (genDebugInfo) \
	{ \
		(psBlock)->psDebug = (SCRIPT_DEBUG *)malloc(sizeof(SCRIPT_DEBUG) * (num)); \
		if ((psBlock)->psDebug == NULL) \
		{ \
			scr_error("Out of memory"); \
			ALLOC_ERROR_ACTION; \
		} \
		memset((psBlock)->psDebug, 0, sizeof(SCRIPT_DEBUG) * (num));\
		(psBlock)->debugEntries = (UWORD)(num); \
	} \
	else \
	{ \
		(psBlock)->psDebug = NULL; \
		(psBlock)->debugEntries = 0; \
	}

/* Macro to free debugging info */
#define FREE_DEBUG(psBlock) \
	if (genDebugInfo) \
		free((psBlock)->psDebug)


/* Macro to copy the debugging information from one block to another */
#define PUT_DEBUG(psFinal, psBlock) \
	if (genDebugInfo) \
	{ \
		memcpy((psFinal)->psDebug, (psBlock)->psDebug, \
					sizeof(SCRIPT_DEBUG) * (psBlock)->debugEntries); \
		(psFinal)->debugEntries = (psBlock)->debugEntries; \
	}

/* Macro to combine the debugging information in two blocks into a third block */
static UDWORD		_dbEntry;
static SCRIPT_DEBUG	*_psCurr;
#define COMBINE_DEBUG(psFinal, psBlock1, psBlock2) \
	if (genDebugInfo) \
	{ \
		memcpy((psFinal)->psDebug, (psBlock1)->psDebug, \
				 sizeof(SCRIPT_DEBUG) * (psBlock1)->debugEntries); \
		_baseOffset = (psBlock1)->size / sizeof(UDWORD); \
		for(_dbEntry = 0; _dbEntry < (psBlock2)->debugEntries; _dbEntry++) \
		{ \
			_psCurr = (psFinal)->psDebug + (psBlock1)->debugEntries + _dbEntry; \
			_psCurr->line = (psBlock2)->psDebug[_dbEntry].line; \
			_psCurr->offset = (psBlock2)->psDebug[_dbEntry].offset + _baseOffset; \
		} \
		(psFinal)->debugEntries = (psBlock1)->debugEntries + (psBlock2)->debugEntries; \
	}

/* Macro to append some debugging information onto a block, given the instruction
   offset of the debugging information already in the destination block */
#define APPEND_DEBUG(psFinal, baseOffset, psBlock) \
	if (genDebugInfo) \
	{ \
		for(_dbEntry = 0; _dbEntry < (psBlock)->debugEntries; _dbEntry++) \
		{ \
			_psCurr = (psFinal)->psDebug + (psFinal)->debugEntries + _dbEntry; \
			_psCurr->line = (psBlock)->psDebug[_dbEntry].line; \
			_psCurr->offset = (psBlock)->psDebug[_dbEntry].offset + (baseOffset); \
		} \
		(psFinal)->debugEntries = (UWORD)((psFinal)->debugEntries + (psBlock)->debugEntries); \
	}


/* Macro to store a label in the debug info */
#define DEBUG_LABEL(psBlock, offset, pString) \
	if (genDebugInfo) \
	{ \
		(psBlock)->psDebug[offset].pLabel = malloc(strlen(pString)+1); \
		if (!(psBlock)->psDebug[offset].pLabel) \
		{ \
			scr_error("Out of memory"); \
			ALLOC_ERROR_ACTION; \
		} \
		strcpy((psBlock)->psDebug[offset].pLabel, pString); \
	}


/***************************************************************************************
 *
 * Code generation functions
 *
 * These functions are used within rule bodies to generate code.
 */

/* Macro to deal with the errors returned by code generation functions.
 * Used within the rule body.
 */
#define CHECK_CODE_ERROR(error) \
	if ((error) == CE_MEMORY) \
	{ \
		YYABORT; \
	} \
	else if ((error) == CE_PARSE) \
	{ \
		YYERROR; \
	}

void script_debug(const char *pFormat, ...)
{
	char    buffer[500];
	va_list pArgs;

	va_start(pArgs, pFormat);
	vsnprintf(buffer, sizeof(buffer), pFormat, pArgs);
	va_end(pArgs);

	debug(LOG_SCRIPT, "%s", buffer);
}

/* Generate the code for a function call, checking the parameter
 * types match.
 */
static CODE_ERROR scriptCodeFunction(FUNC_SYMBOL	*psFSymbol,		// The function being called
							PARAM_BLOCK		*psPBlock,		// The functions parameters
							BOOL			expContext,		// Whether the function is being
															// called in an expression context
							CODE_BLOCK		**ppsCBlock)	// The generated code block
{
	UDWORD		size, i;
	INTERP_VAL	*ip;
	BOOL		typeError = false;
	char		aErrorString[255];
	INTERP_TYPE	type1,type2;

	ASSERT( psFSymbol != NULL, "ais_CodeFunction: Invalid function symbol pointer" );
	ASSERT( psPBlock != NULL,
		"scriptCodeFunction: Invalid param block pointer" );
	ASSERT( (psPBlock->size == 0) || psPBlock->pCode != NULL,
		"scriptCodeFunction: Invalid parameter code pointer" );
	ASSERT( ppsCBlock != NULL,
		 "scriptCodeFunction: Invalid generated code block pointer" );

	/* Check the parameter types match what the function needs */
	for(i=0; (i<psFSymbol->numParams) && (i<psPBlock->numParams); i++)
	{
/*		if (psFSymbol->aParams[i] != VAL_VOID &&
			psFSymbol->aParams[i] != psPBlock->aParams[i])*/
		//TODO: string support
		if(psFSymbol->aParams[i] != VAL_STRING)	// string - allow mixed types if string is parameter type	//TODO: tweak this
		{
			type1 = psFSymbol->aParams[i];
			type2 = psPBlock->aParams[i];
			if (!interpCheckEquiv(type1, type2))
			{
				debug(LOG_ERROR, "scriptCodeFunction: Type mismatch for parameter %d (%d/%d)", i, psFSymbol->aParams[i], psPBlock->aParams[i]);
				snprintf(aErrorString, sizeof(aErrorString), "Type mismatch for parameter %d", i);
				scr_error("%s", aErrorString);
				typeError = true;
			}
		}
		//else
		//{
		//	debug(LOG_SCRIPT, "scriptCodeFunction: %s takes string as parameter %d (provided: %d)", psFSymbol->pIdent, i, psPBlock->aParams[i]);
		//}
	}

	/* Check the number of parameters matches that expected */
	if (psFSymbol->numParams != psPBlock->numParams)
	{
		snprintf(aErrorString, sizeof(aErrorString), "Expected %d parameters", psFSymbol->numParams);
		scr_error("%s", aErrorString);
		*ppsCBlock = NULL;
		return CE_PARSE;
	}

	if (typeError)
	{
		/* Report the error here so all the */
		/* type mismatches are reported */
		*ppsCBlock = NULL;
		return CE_PARSE;
	}

	//size = psPBlock->size + sizeof(OPCODE) + sizeof(SCRIPT_FUNC);
	size = psPBlock->size + 1 + 1;	//size + opcode + sizeof(SCRIPT_FUNC)

	if (!expContext && (psFSymbol->type != VAL_VOID))
	{
		//size += sizeof(OPCODE);
		size += 1;	//+ 1 additional opcode to pop value if needed
	}

	ALLOC_BLOCK(*ppsCBlock, size);
	ip = (*ppsCBlock)->pCode;
	(*ppsCBlock)->type = psFSymbol->type;

	/* Copy in the code for the parameters */
	PUT_BLOCK(ip, psPBlock);
	FREE_PBLOCK(psPBlock);

	/* Make the function call */
	if (psFSymbol->script)
	{
		/* function defined in this script */
//		PUT_OPCODE(ip, OP_FUNC);
//		PUT_SCRIPTFUNC(ip, psFSymbol);
		ASSERT(false, "wrong function type call");
	}
	else
	{
		/* call an instinct function */
		PUT_OPCODE(ip, OP_CALL);
		PUT_FUNC_EXTERN(ip, psFSymbol->pFunc);
	}

	if (!expContext && (psFSymbol->type != VAL_VOID))
	{
		/* Clear the return value from the stack */
		PUT_OPCODE(ip, OP_POP);
	}

	return CE_OK;
}


/* Function call: Check the parameter types match, assumes param count matched */
static UDWORD checkFuncParamTypes(EVENT_SYMBOL		*psFSymbol,		// The function being called
							PARAM_BLOCK		*psPBlock)	// The generated code block
{
	UDWORD		i;

	//debug(LOG_SCRIPT,"checkFuncParamTypes");

	/* Check the parameter types match what the function needs */
	for(i=0; (i<psFSymbol->numParams) && (i<psPBlock->numParams); i++)
	{
		//TODO: string support
		//if(psFSymbol->aParams[i] != VAL_STRING)	// string - allow mixed types if string is parameter type
		//{
			if (!interpCheckEquiv(psFSymbol->aParams[i], psPBlock->aParams[i]))
			{
				debug(LOG_ERROR, "checkFuncParamTypes: Type mismatch for parameter %d ('1' based) in Function '%s' (provided type: %d, expected: %d)", (i+1), psFSymbol->pIdent, psPBlock->aParams[i], psFSymbol->aParams[i]);
				scr_error("Parameter type mismatch");
				return i+1;
			}
		//}
	}

	//debug(LOG_SCRIPT,"END checkFuncParamTypes");

	return 0;	//all ok
}

#ifdef UNUSED
/*
 *  function call
 */
static CODE_ERROR scriptCodeCallFunction(FUNC_SYMBOL	*psFSymbol,		// The function being called
						PARAM_BLOCK		*psPBlock,		// The functions parameters
						CODE_BLOCK		**ppsCBlock)	// The generated code block
{
	UDWORD		size;
	INTERP_VAL	*ip;

	//debug(LOG_SCRIPT, "scriptCodeCallFunction");

	ASSERT( psFSymbol != NULL, "scriptCodeCallFunction: Invalid function symbol pointer" );
	ASSERT( psPBlock != NULL,
		"scriptCodeCallFunction: Invalid param block pointer" );
	ASSERT( (psPBlock->size == 0) || psPBlock->pCode != NULL,
		"scriptCodeCallFunction: Invalid parameter code pointer" );
	ASSERT( ppsCBlock != NULL,
		 "scriptCodeCallFunction: Invalid generated code block pointer" );


	//size = psPBlock->size + sizeof(OPCODE) + sizeof(SCRIPT_FUNC);
	size = psPBlock->size + 1 + 1;	//size + opcode + SCRIPT_FUNC

	ALLOC_BLOCK(*ppsCBlock, size);
	ip = (*ppsCBlock)->pCode;
	(*ppsCBlock)->type = psFSymbol->type;

	/* Copy in the code for the parameters */
	PUT_BLOCK(ip, psPBlock);
	FREE_PBLOCK(psPBlock);

	/* Make the function call */
	PUT_OPCODE(ip, OP_CALL);
	PUT_FUNC_EXTERN(ip, psFSymbol->pFunc);

	//debug(LOG_SCRIPT, "END scriptCodeCallFunction");

	return CE_OK;
}
#endif

/* Generate the code for a parameter callback, checking the parameter
 * types match.
 */
static CODE_ERROR scriptCodeCallbackParams(
							CALLBACK_SYMBOL	*psCBSymbol,	// The callback being called
							PARAM_BLOCK		*psPBlock,		// The callbacks parameters
							TRIGGER_DECL	**ppsTDecl)		// The generated code block
{
	UDWORD		size, i;
	INTERP_VAL	*ip;
	BOOL		typeError = false;
	char		aErrorString[255];

	ASSERT( psPBlock != NULL,
		"scriptCodeCallbackParams: Invalid param block pointer" );
	ASSERT( (psPBlock->size == 0) || psPBlock->pCode != NULL,
		"scriptCodeCallbackParams: Invalid parameter code pointer" );
	ASSERT( ppsTDecl != NULL,
		 "scriptCodeCallbackParams: Invalid generated code block pointer" );
	ASSERT( psCBSymbol->pFunc != NULL,
		 "scriptCodeCallbackParams: Expected function pointer for callback symbol" );

	/* Check the parameter types match what the function needs */
	for(i=0; (i<psCBSymbol->numParams) && (i<psPBlock->numParams); i++)
	{
		if (!interpCheckEquiv(psCBSymbol->aParams[i], psPBlock->aParams[i]))
		{
			snprintf(aErrorString, sizeof(aErrorString), "Type mismatch for parameter %d", i);
			scr_error("%s", aErrorString);
			typeError = true;
		}
	}

	/* Check the number of parameters matches that expected */
	if (psPBlock->numParams == 0)
	{
		scr_error("Expected parameters to callback");
		*ppsTDecl = NULL;
		return CE_PARSE;
	}
	else if (psCBSymbol->numParams != psPBlock->numParams)
	{
		snprintf(aErrorString, sizeof(aErrorString), "Expected %d parameters", psCBSymbol->numParams);
		scr_error("%s", aErrorString);
		*ppsTDecl = NULL;
		return CE_PARSE;
	}
	if (typeError)
	{
		/* Return the error here so all the */
		/* type mismatches are reported */
		*ppsTDecl = NULL;
		return CE_PARSE;
	}

	//size = psPBlock->size + sizeof(OPCODE) + sizeof(SCRIPT_FUNC);
	size = psPBlock->size + 1 + 1;		//size + opcode + SCRIPT_FUNC

	ALLOC_TSUBDECL(*ppsTDecl, psCBSymbol->type, size, 0);
	ip = (*ppsTDecl)->pCode;

	/* Copy in the code for the parameters */
	PUT_BLOCK(ip, psPBlock);
	FREE_PBLOCK(psPBlock);

	/* call the instinct function */
	PUT_OPCODE(ip, OP_CALL);
	PUT_FUNC_EXTERN(ip, psCBSymbol->pFunc);

	return CE_OK;
}


/* Generate code for assigning a value to a variable */
static CODE_ERROR scriptCodeAssignment(VAR_SYMBOL	*psVariable,	// The variable to assign to
							  CODE_BLOCK	*psValue,		// The code for the value to
															// assign
							  CODE_BLOCK	**ppsBlock)		// Generated code
{
	SDWORD		size;

	ASSERT( psVariable != NULL,
		"scriptCodeAssignment: Invalid variable symbol pointer" );
	ASSERT( psValue != NULL,
		"scriptCodeAssignment: Invalid value code block pointer" );
	ASSERT( psValue->pCode != NULL,
		"scriptCodeAssignment: Invalid value code pointer" );
	ASSERT( ppsBlock != NULL,
		"scriptCodeAssignment: Invalid generated code block pointer" );

	//size = psValue->size + sizeof(OPCODE);
	size = psValue->size + 1;		//1 - for assignment opcode

	if (psVariable->storage == ST_EXTERN)
	{
		// Check there is a set function
		if (psVariable->set == NULL)
		{
			scr_error("No set function for external variable");
			return CE_PARSE;
		}

		//size += sizeof(SCRIPT_VARFUNC);
		size += 1;		//1 - for set func pointer
	}
	ALLOC_BLOCK(*ppsBlock, size);
	ip = (*ppsBlock)->pCode;

	/* Copy in the code for the expression */
	PUT_BLOCK(ip, psValue);
	FREE_BLOCK(psValue);

	/* Code to get the value from the stack into the variable */
	switch (psVariable->storage)
	{
	case ST_PUBLIC:
	case ST_PRIVATE:
		PUT_PKOPCODE(ip, OP_POPGLOBAL, psVariable->index);
		break;
	case ST_LOCAL:
		PUT_PKOPCODE(ip, OP_POPLOCAL, psVariable->index);
		break;
	case ST_EXTERN:
		PUT_PKOPCODE(ip, OP_VARCALL, psVariable->index);
		PUT_VARFUNC(ip, psVariable->set);
		break;
	case ST_OBJECT:
		scr_error("Cannot use member variables in this context");
		return CE_PARSE;
		break;
	default:
		scr_error("Unknown storage type");
		return CE_PARSE;
		break;
	}

	return CE_OK;
}


/* Generate code for assigning a value to an object variable */
static CODE_ERROR scriptCodeObjAssignment(OBJVAR_BLOCK	*psVariable,// The variable to assign to
								 CODE_BLOCK		*psValue,	// The code for the value to
															// assign
								 CODE_BLOCK		**ppsBlock)	// Generated code
{
	ASSERT( psVariable != NULL,
		"scriptCodeObjAssignment: Invalid object variable block pointer" );
	ASSERT( psVariable->pCode != NULL,
		"scriptCodeObjAssignment: Invalid object variable code pointer" );
	ASSERT( psVariable->psObjVar != NULL,
		"scriptCodeObjAssignment: Invalid object variable symbol pointer" );
	ASSERT( psValue != NULL,
		"scriptCodeObjAssignment: Invalid value code block pointer" );
	ASSERT( psValue->pCode != NULL,
		"scriptCodeObjAssignment: Invalid value code pointer" );
	ASSERT( ppsBlock != NULL,
		"scriptCodeObjAssignment: Invalid generated code block pointer" );

	// Check there is an access function for the variable
	if (psVariable->psObjVar->set == NULL)
	{
		scr_error("No set function for object variable");
		return CE_PARSE;
	}

	//ALLOC_BLOCK(*ppsBlock, psVariable->size + psValue->size + sizeof(OPCODE) + sizeof(SCRIPT_VARFUNC));
	ALLOC_BLOCK(*ppsBlock, psVariable->size + psValue->size + 1 + 1);	//size + size + opcode + 'sizeof(SCRIPT_VARFUNC)'

	ip = (*ppsBlock)->pCode;

	/* Copy in the code for the value */
	PUT_BLOCK(ip, psValue);
	FREE_BLOCK(psValue);

	/* Copy in the code for the object */
	PUT_BLOCK(ip, psVariable);

	/* Code to get the value from the stack into the variable */
	PUT_PKOPCODE(ip, OP_VARCALL, psVariable->psObjVar->index);
	PUT_VARFUNC(ip, (psVariable->psObjVar->set));

	/* Free the variable block */
	FREE_OBJVARBLOCK(psVariable);

	return CE_OK;
}


/* Generate code for getting a value from an object variable */
static CODE_ERROR scriptCodeObjGet(OBJVAR_BLOCK	*psVariable,// The variable to get from
						  CODE_BLOCK	**ppsBlock)	// Generated code
{
	ASSERT( psVariable != NULL,
		"scriptCodeObjAssignment: Invalid object variable block pointer" );
	ASSERT( psVariable->pCode != NULL,
		"scriptCodeObjAssignment: Invalid object variable code pointer" );
	ASSERT( psVariable->psObjVar != NULL,
		"scriptCodeObjAssignment: Invalid object variable symbol pointer" );
	ASSERT( ppsBlock != NULL,
		"scriptCodeObjAssignment: Invalid generated code block pointer" );

	// Check there is an access function for the variable
	if (psVariable->psObjVar->get == NULL)
	{
		scr_error("No get function for object variable");
		return CE_PARSE;
	}

	//ALLOC_BLOCK(*ppsBlock, psVariable->size + sizeof(OPCODE) + sizeof(SCRIPT_VARFUNC));
	ALLOC_BLOCK(*ppsBlock, psVariable->size + 1 + 1);	//size + opcode + SCRIPT_VARFUNC

	ip = (*ppsBlock)->pCode;

	/* Copy in the code for the object */
	PUT_BLOCK(ip, psVariable);
	(*ppsBlock)->type = psVariable->psObjVar->type;

	/* Code to get the value from the object onto the stack */
	PUT_PKOPCODE(ip, OP_VARCALL, psVariable->psObjVar->index);
	PUT_VARFUNC(ip, psVariable->psObjVar->get);

	/* Free the variable block */
	FREE_OBJVARBLOCK(psVariable);

	return CE_OK;
}


/* Generate code for assigning a value to an array variable */
static CODE_ERROR scriptCodeArrayAssignment(ARRAY_BLOCK	*psVariable,// The variable to assign to
								 CODE_BLOCK		*psValue,	// The code for the value to
															// assign
								 CODE_BLOCK		**ppsBlock)	// Generated code
{
//	SDWORD		elementDWords, i;
//	UBYTE		*pElement;

	ASSERT( psVariable != NULL,
		"scriptCodeObjAssignment: Invalid object variable block pointer" );
	ASSERT( psVariable->pCode != NULL,
		"scriptCodeObjAssignment: Invalid object variable code pointer" );
	ASSERT( psVariable->psArrayVar != NULL,
		"scriptCodeObjAssignment: Invalid object variable symbol pointer" );
	ASSERT( psValue != NULL,
		"scriptCodeObjAssignment: Invalid value code block pointer" );
	ASSERT( psValue->pCode != NULL,
		"scriptCodeObjAssignment: Invalid value code pointer" );
	ASSERT( ppsBlock != NULL,
		"scriptCodeObjAssignment: Invalid generated code block pointer" );

	// Check this is an array
	if (psVariable->psArrayVar->dimensions == 0)
	{
		scr_error("Not an array variable");
		return CE_PARSE;
	}

	// calculate the number of DWORDs needed to store the number of elements for each dimension of the array
//	elementDWords = (psVariable->psArrayVar->dimensions - 1)/4 + 1;

//	ALLOC_BLOCK(*ppsBlock, psVariable->size + psValue->size + sizeof(OPCODE) + elementDWords*4);
	//ALLOC_BLOCK(*ppsBlock, psVariable->size + psValue->size + sizeof(OPCODE));
	ALLOC_BLOCK(*ppsBlock, psVariable->size + psValue->size + 1);	//size + size + opcode

	ip = (*ppsBlock)->pCode;

	/* Copy in the code for the value */
	PUT_BLOCK(ip, psValue);
	FREE_BLOCK(psValue);

	/* Copy in the code for the array index */
	PUT_BLOCK(ip, psVariable);

	/* Code to get the value from the stack into the variable */
	PUT_PKOPCODE(ip, OP_POPARRAYGLOBAL,
		((psVariable->psArrayVar->dimensions << ARRAY_DIMENSION_SHIFT) & ARRAY_DIMENSION_MASK) |
		(psVariable->psArrayVar->index & ARRAY_BASE_MASK) );

	// store the size of each dimension
/*	pElement = (UBYTE *)ip;
	for(i=0; i<psVariable->psArrayVar->dimensions; i++)
	{
		*pElement = (UBYTE)psVariable->psArrayVar->elements[i];
		pElement += 1;
	}*/

	/* Free the variable block */
	FREE_ARRAYBLOCK(psVariable);

	return CE_OK;
}


/* Generate code for getting a value from an array variable */
static CODE_ERROR scriptCodeArrayGet(ARRAY_BLOCK	*psVariable,// The variable to get from
						  CODE_BLOCK	**ppsBlock)	// Generated code
{
//	SDWORD		elementDWords, i;
//	UBYTE		*pElement;

	ASSERT( psVariable != NULL,
		"scriptCodeObjAssignment: Invalid object variable block pointer" );
	ASSERT( psVariable->pCode != NULL,
		"scriptCodeObjAssignment: Invalid object variable code pointer" );
	ASSERT( psVariable->psArrayVar != NULL,
		"scriptCodeObjAssignment: Invalid object variable symbol pointer" );
	ASSERT( ppsBlock != NULL,
		"scriptCodeObjAssignment: Invalid generated code block pointer" );

	// Check this is an array
	if (psVariable->psArrayVar->dimensions == 0)
	{
		scr_error("Not an array variable");
		return CE_PARSE;
	}

	// calculate the number of DWORDs needed to store the number of elements for each dimension of the array
//	elementDWords = (psVariable->psArrayVar->dimensions - 1)/4 + 1;

//	ALLOC_BLOCK(*ppsBlock, psVariable->size + sizeof(OPCODE) + elementDWords*4);
	//ALLOC_BLOCK(*ppsBlock, psVariable->size + sizeof(OPCODE));
	ALLOC_BLOCK(*ppsBlock, psVariable->size + 1);	//size + opcode

	ip = (*ppsBlock)->pCode;

	/* Copy in the code for the array index */
	PUT_BLOCK(ip, psVariable);
	(*ppsBlock)->type = psVariable->psArrayVar->type;

	/* Code to get the value from the array onto the stack */
	PUT_PKOPCODE(ip, OP_PUSHARRAYGLOBAL,
		((psVariable->psArrayVar->dimensions << ARRAY_DIMENSION_SHIFT) & ARRAY_DIMENSION_MASK) |
		(psVariable->psArrayVar->index & ARRAY_BASE_MASK) );

	// store the size of each dimension
/*	pElement = (UBYTE *)ip;
	for(i=0; i<psVariable->psArrayVar->dimensions; i++)
	{
		*pElement = (UBYTE)psVariable->psArrayVar->elements[i];
		pElement += 1;
	}*/

	/* Free the variable block */
	FREE_ARRAYBLOCK(psVariable);

	return CE_OK;
}


/* Generate the final code block for conditional statements */
static CODE_ERROR scriptCodeConditional(
					COND_BLOCK *psCondBlock,	// The intermediate conditional code
					CODE_BLOCK **ppsBlock)		// The final conditional code
{
	UDWORD		i;

	ASSERT( psCondBlock != NULL,
		"scriptCodeConditional: Invalid conditional code block pointer" );
	ASSERT( psCondBlock->pCode != NULL,
		"scriptCodeConditional: Invalid conditional code pointer" );
	ASSERT( ppsBlock != NULL,
		"scriptCodeConditional: Invalid generated code block pointer" );

	/* Allocate the final block */
	ALLOC_BLOCK(*ppsBlock, psCondBlock->size);
	ALLOC_DEBUG(*ppsBlock, psCondBlock->debugEntries);
	ip = (*ppsBlock)->pCode;

	/* Copy the code over */
	PUT_BLOCK(ip, psCondBlock);

	/* Copy the debugging information */
	PUT_DEBUG(*ppsBlock, psCondBlock);

	/* Now set the offsets of jumps in the conditional to the correct value */
	for(i = 0; i < psCondBlock->numOffsets; i++)
	{
		ip = (*ppsBlock)->pCode + psCondBlock->aOffsets[i];
		// *ip = ((*ppsBlock)->size / sizeof(UDWORD)) - (ip - (*ppsBlock)->pCode);

		ip->type = VAL_PKOPCODE;
		ip->v.ival = (*ppsBlock)->size - (ip - (*ppsBlock)->pCode);
		ip->v.ival = (OP_JUMP << OPCODE_SHIFT) | ( (ip->v.ival) & OPCODE_DATAMASK );
	}

	/* Free the original code */
	FREE_DEBUG(psCondBlock);
	FREE_CONDBLOCK(psCondBlock);

	return CE_OK;
}

/* Generate code for function parameters */
static CODE_ERROR scriptCodeParameter(CODE_BLOCK		*psParam,		// Code for the parameter
							 INTERP_TYPE		type,			// Parameter type
							 PARAM_BLOCK	**ppsBlock)		// Generated code
{
	ASSERT( psParam != NULL,
		"scriptCodeParameter: Invalid parameter code block pointer" );
	ASSERT( psParam->pCode != NULL,
		"scriptCodeParameter: Invalid parameter code pointer" );
	ASSERT( ppsBlock != NULL,
		"scriptCodeParameter: Invalid generated code block pointer" );

	RULE("	scriptCodeParameter(): type: %d", type);

	ALLOC_PBLOCK(*ppsBlock, psParam->size, 1);
	ip = (*ppsBlock)->pCode;

	/* Copy in the code for the parameter */
	PUT_BLOCK(ip, psParam);
	FREE_BLOCK(psParam);

	(*ppsBlock)->aParams[0] = type;

	return CE_OK;
}


/* Generate code for binary operators (e.g. 2 + 2) */
static CODE_ERROR scriptCodeBinaryOperator(CODE_BLOCK	*psFirst,	// Code for first parameter
								  CODE_BLOCK	*psSecond,	// Code for second parameter
								  OPCODE		opcode,		// Operator function
								  CODE_BLOCK	**ppsBlock) // Generated code
{
	ALLOC_BLOCK(*ppsBlock, psFirst->size + psSecond->size + 1);		//size + size + binary opcode
	ip = (*ppsBlock)->pCode;

	/* Copy the already generated bits of code into the code block */
	PUT_BLOCK(ip, psFirst);
	PUT_BLOCK(ip, psSecond);

	/* Now put an add operator into the code */
	PUT_PKOPCODE(ip, OP_BINARYOP, opcode);

	/* Free the two code blocks that have been copied */
	FREE_BLOCK(psFirst);
	FREE_BLOCK(psSecond);

	return CE_OK;
}

/* check if the arguments in the function definition body match the argument types
and names from function declaration (if there was any) */
static BOOL checkFuncParamType(UDWORD argIndex, UDWORD argType)
{
	VAR_SYMBOL		*psCurr;
	SDWORD			i,j;

	if(psCurEvent == NULL)
	{
		debug(LOG_ERROR, "checkFuncParamType() - psCurEvent == NULL");
		return false;
	}

	if(argIndex < psCurEvent->numParams)
	{
		/* find the argument by the index */
		i=psCurEvent->index;
		j=0;
		for(psCurr = psLocalVarsB[i]; psCurr != NULL; psCurr = psCurr->psNext)
		{
			if((psCurEvent->numParams - j - 1)==argIndex)	/* got to the right argument */
			{
				if(argType != psCurr->type)
				{
					debug(LOG_ERROR, "Argument type with index %d in event '%s' doesn't match function declaration (%d/%d)",argIndex,psCurEvent->pIdent,argType,psCurr->type);
					return false;
				}
				else
				{
					//debug(LOG_SCRIPT, "arg matched ");
					return true;
				}
			}
			j++;
		}
	}
	else
	{
		debug(LOG_ERROR, "checkFuncParamType() - argument %d has wrong argument index, event: '%s'", argIndex, psCurEvent->pIdent);
		return false;
	}

	return false;
}


/* Generate code for accessing an object variable.  The variable symbol is
 * stored with the code for the object value so that this block can be used for
 * both setting and retrieving an object value.
 */
static CODE_ERROR scriptCodeObjectVariable(CODE_BLOCK	*psObjCode,	// Code for the object value
								  VAR_SYMBOL	*psVar,		// The object variable symbol
								  OBJVAR_BLOCK	**ppsBlock) // Generated code
{
	ASSERT( psObjCode != NULL,
		"scriptCodeObjectVariable: Invalid object code block pointer" );
	ASSERT( psObjCode->pCode != NULL,
		"scriptCodeObjectVariable: Invalid object code pointer" );
	ASSERT( psVar != NULL,
		"scriptCodeObjectVariable: Invalid variable symbol pointer" );
	ASSERT( ppsBlock != NULL,
		"scriptCodeObjectVariable: Invalid generated code block pointer" );

	ALLOC_OBJVARBLOCK(*ppsBlock, psObjCode->size, psVar);
	ip = (*ppsBlock)->pCode;

	/* Copy the already generated bit of code into the code block */
	PUT_BLOCK(ip, psObjCode);
	FREE_BLOCK(psObjCode);

	/* Check the variable is the correct type */
	if (psVar->storage != ST_OBJECT)
	{
		scr_error("Only object variables are valid in this context");
		return CE_PARSE;
	}

	return CE_OK;
}


/* Generate code for accessing an array variable.  The variable symbol is
 * stored with the code for the object value so that this block can be used for
 * both setting and retrieving an array value.
 */
static CODE_ERROR scriptCodeArrayVariable(ARRAY_BLOCK	*psArrayCode,	// Code for the array index
								  VAR_SYMBOL	*psVar,			// The array variable symbol
								  ARRAY_BLOCK	**ppsBlock)		// Generated code
{
	ASSERT( psArrayCode != NULL,
		"scriptCodeObjectVariable: Invalid object code block pointer" );
	ASSERT( psArrayCode->pCode != NULL,
		"scriptCodeObjectVariable: Invalid object code pointer" );
	ASSERT( psVar != NULL,
		"scriptCodeObjectVariable: Invalid variable symbol pointer" );
	ASSERT( ppsBlock != NULL,
		"scriptCodeObjectVariable: Invalid generated code block pointer" );

/*	ALLOC_ARRAYBLOCK(*ppsBlock, psArrayCode->size, psVar);
	ip = (*ppsBlock)->pCode;

	// Copy the already generated bit of code into the code block
	PUT_BLOCK(ip, psArrayCode);
	FREE_BLOCK(psArrayCode);*/

	// Check the variable is the correct type
	if (psVar->dimensions != psArrayCode->dimensions)
	{
		scr_error("Invalid number of array dimensions for this variable");
		return CE_PARSE;
	}

	psArrayCode->psArrayVar = psVar;
	*ppsBlock = psArrayCode;

	return CE_OK;
}


/* Generate code for a constant */
static CODE_ERROR scriptCodeConstant(CONST_SYMBOL	*psConst,	// The object variable symbol
							CODE_BLOCK		**ppsBlock)	// Generated code
{
	ASSERT( psConst != NULL,
		"scriptCodeConstant: Invalid constant symbol pointer" );
	ASSERT( ppsBlock != NULL,
		"scriptCodeConstant: Invalid generated code block pointer" );

	//ALLOC_BLOCK(*ppsBlock, sizeof(OPCODE) + sizeof(UDWORD));
	ALLOC_BLOCK(*ppsBlock, 1 + 1);		//OP_PUSH opcode + variable value

	ip = (*ppsBlock)->pCode;
	(*ppsBlock)->type = psConst->type;

	/* Put the value onto the stack */
	switch (psConst->type)
	{
	case VAL_FLOAT:
		RULE("	scriptCodeConstant: pushing float");
		PUT_PKOPCODE(ip, OP_PUSH, VAL_FLOAT);
		PUT_DATA_FLOAT(ip, psConst->fval);
		break;
	case VAL_BOOL:
		RULE("	scriptCodeConstant: pushing bool");
		PUT_PKOPCODE(ip, OP_PUSH, VAL_BOOL);
		PUT_DATA_BOOL(ip, psConst->bval);
		break;
	case VAL_INT:
		RULE("	scriptCodeConstant: pushing int");
		PUT_PKOPCODE(ip, OP_PUSH, VAL_INT);
		PUT_DATA_INT(ip, psConst->ival);
		break;
	case VAL_STRING:
		RULE("	scriptCodeConstant: pushing string");
		PUT_PKOPCODE(ip, OP_PUSH, VAL_STRING);
		PUT_DATA_STRING(ip, psConst->sval);
		break;
	default:	/* Object/user constants */
		RULE("	scriptCodeConstant: pushing object/ user var (type: %d)", psConst->type);
		PUT_PKOPCODE(ip, OP_PUSH, psConst->type);
		PUT_OBJECT_CONST(ip, psConst->oval, psConst->type);		//TODO: differentiate types
		break;
	}

	return CE_OK;
}


/* Generate code for getting a variables value */
static CODE_ERROR scriptCodeVarGet(VAR_SYMBOL		*psVariable,	// The object variable symbol
							CODE_BLOCK		**ppsBlock)		// Generated code
{
	SDWORD size = 1; //1 - for opcode

	if (psVariable->storage == ST_EXTERN)
	{
		// Check there is a set function
		if (psVariable->get == NULL)
		{
			scr_error("No get function for external variable");
			return CE_PARSE;
		}

		size++;
	}

	ALLOC_BLOCK(*ppsBlock, size);
	ip = (*ppsBlock)->pCode;
	(*ppsBlock)->type = psVariable->type;

	/* Code to get the value onto the stack */
	switch (psVariable->storage)
	{
	case ST_PUBLIC:
	case ST_PRIVATE:
		PUT_PKOPCODE(ip, OP_PUSHGLOBAL, psVariable->index);
		break;
	case ST_LOCAL:
		PUT_PKOPCODE(ip, OP_PUSHLOCAL, psVariable->index);	//opcode + event index
		break;
	case ST_EXTERN:
		PUT_PKOPCODE(ip, OP_VARCALL, psVariable->index);
		PUT_VARFUNC(ip, psVariable->get);
		break;
	case ST_OBJECT:
		scr_error("Cannot use member variables in this context");
		return CE_PARSE;
		break;
	default:
		scr_error("Unknown storage type");
		return CE_PARSE;
		break;
	}

	return CE_OK;
}

/* Code Increment/Decrement operators */
static CODE_ERROR scriptCodeIncDec(VAR_SYMBOL		*psVariable,	// The object variable symbol
							CODE_BLOCK		**ppsBlock, OPCODE op_dec_inc)
{

	ALLOC_BLOCK(*ppsBlock, 1 + 1 + 1);	//OP_PUSHREF opcode + variable index + inc opcode
	ip = (*ppsBlock)->pCode;
	(*ppsBlock)->type = psVariable->type;

	/* Put variable index */
	switch (psVariable->storage)
	{
	case ST_PRIVATE:
		PUT_PKOPCODE(ip, OP_PUSHREF, psVariable->type | VAL_REF);
		PUT_DATA_INT(ip, psVariable->index);
		break;
	case ST_LOCAL:
		PUT_PKOPCODE(ip, OP_PUSHLOCALREF, psVariable->type | VAL_REF);
		PUT_DATA_INT(ip, psVariable->index);
		break;
	default:
		scr_error("Wrong variable storage type for increment/decrement operator");
		break;
	}

	/* Put inc/dec opcode */
	PUT_PKOPCODE(ip, OP_UNARYOP, op_dec_inc);

	return CE_OK;
}


/* Generate code for getting a variables value */
static CODE_ERROR scriptCodeVarRef(VAR_SYMBOL		*psVariable,	// The object variable symbol
							PARAM_BLOCK		**ppsBlock)		// Generated code
{
	SDWORD	size;

	//size = sizeof(OPCODE) + sizeof(SDWORD);
	size = 1 + 1;	//OP_PUSHREF opcode + variable index

	ALLOC_PBLOCK(*ppsBlock, size, 1);
	ip = (*ppsBlock)->pCode;

	(*ppsBlock)->aParams[0] = psVariable->type | VAL_REF;

	/* Code to get the value onto the stack */
	switch (psVariable->storage)
	{
	case ST_PUBLIC:
	case ST_PRIVATE:

		PUT_PKOPCODE(ip, OP_PUSHREF, (*ppsBlock)->aParams[0]);
		PUT_DATA_INT(ip, psVariable->index);	//TODO: add new macro
		break;

	case ST_LOCAL:
		PUT_PKOPCODE(ip, OP_PUSHLOCALREF, (*ppsBlock)->aParams[0]);
		PUT_DATA_INT(ip, psVariable->index);
		break;
	case ST_EXTERN:
		scr_error("Cannot use external variables in this context");
		return CE_PARSE;
		break;
	case ST_OBJECT:
		scr_error("Cannot use member variables in this context");
		return CE_PARSE;
		break;
	default:
		scr_error("Unknown storage type: %d", psVariable->storage);
		return CE_PARSE;
		break;
	}

	return CE_OK;
}

#ifdef UNUSED
/* Generate the code for a trigger and store it in the trigger list */
static CODE_ERROR scriptCodeTrigger(char *pIdent, CODE_BLOCK *psCode)
{
	CODE_BLOCK		*psNewBlock;
	UDWORD			line;
	char			*pDummy;

	// Have to add the exit code to the end of the event
	//ALLOC_BLOCK(psNewBlock, psCode->size + sizeof(OPCODE));
	ALLOC_BLOCK(psNewBlock, psCode->size + 1);	//size + opcode

	ip = psNewBlock->pCode;
	PUT_BLOCK(ip, psCode);
	PUT_OPCODE(ip, OP_EXIT);

	// Add the debug info
	ALLOC_DEBUG(psNewBlock, psCode->debugEntries + 1);
	PUT_DEBUG(psNewBlock, psCode);
	if (genDebugInfo)
	{
		/* Add debugging info for the EXIT instruction */
		scriptGetErrorData((SDWORD *)&line, &pDummy);
		psNewBlock->psDebug[psNewBlock->debugEntries].line = line;
		psNewBlock->psDebug[psNewBlock->debugEntries].offset =
				ip - psNewBlock->pCode;
		psNewBlock->debugEntries ++;
	}
	FREE_BLOCK(psCode);

	// Create the trigger
/*	if (!scriptAddTrigger(pIdent, psNewBlock))
	{
		return CE_MEMORY;
	}*/

	return CE_OK;
}
#endif

#ifdef UNUSED
/* Generate the code for an event and store it in the event list */
static CODE_ERROR scriptCodeEvent(EVENT_SYMBOL *psEvent, TRIGGER_SYMBOL *psTrig, CODE_BLOCK *psCode)
{
	CODE_BLOCK		*psNewBlock;
	UDWORD			line;
	char			*pDummy;

	// Have to add the exit code to the end of the event
	//ALLOC_BLOCK(psNewBlock, psCode->size + sizeof(OPCODE));
	ALLOC_BLOCK(psNewBlock, psCode->size + 1);	//size + opcode

	ip = psNewBlock->pCode;
	PUT_BLOCK(ip, psCode);
	PUT_OPCODE(ip, OP_EXIT);

	// Add the debug info
	ALLOC_DEBUG(psNewBlock, psCode->debugEntries + 1);
	PUT_DEBUG(psNewBlock, psCode);
	if (genDebugInfo)
	{
		/* Add debugging info for the EXIT instruction */
		scriptGetErrorData((SDWORD *)&line, &pDummy);
		psNewBlock->psDebug[psNewBlock->debugEntries].line = line;
		psNewBlock->psDebug[psNewBlock->debugEntries].offset =
				ip - psNewBlock->pCode;
		psNewBlock->debugEntries ++;
	}
	FREE_BLOCK(psCode);

	// Create the event
	if (!scriptDefineEvent(psEvent, psNewBlock, psTrig->index))
	{
		return CE_MEMORY;
	}

	return CE_OK;
}
#endif

#ifdef UNUSED
/* Store the types of a list of variables into a code block.
 * The order of the list is reversed so that the type of the
 * first variable defined is stored first.
 */
static void scriptStoreVarTypes(VAR_SYMBOL *psVar)
{
	if (psVar != NULL)
	{
		/* Recurse down the list to get to the end of it */
		scriptStoreVarTypes(psVar->psNext);

		/* Now store the current variable */
		PUT_INDEX(ip, psVar->type);
	}
}
#endif

/* Change the error action for the ALLOC macro's to what it
 * should be inside a rule body.
 *
 * NOTE: DO NOT USE THE ALLOC MACRO'S INSIDE ANY FUNCTIONS
 *       ONCE ALLOC_ERROR_ACTION IS SET TO THIS VALUE.
 *       ALL FUNCTIONS THAT USE THESE MACROS MUST BE PLACED
 *       BEFORE THIS #define.
 */
#undef ALLOC_ERROR_ACTION
#define ALLOC_ERROR_ACTION YYABORT

%}

%name-prefix="scr_"

%union {
	/* Types returned by the lexer */
	BOOL			bval;
	float			fval;
	SDWORD			ival;
	char			*sval;
	INTERP_TYPE		tval;
	STORAGE_TYPE	stype;
	VAR_SYMBOL		*vSymbol;
	CONST_SYMBOL	*cSymbol;
	FUNC_SYMBOL		*fSymbol;
	TRIGGER_SYMBOL	*tSymbol;
	EVENT_SYMBOL	*eSymbol;
	CALLBACK_SYMBOL	*cbSymbol;

	/* Types only returned by rules */
	CODE_BLOCK		*cblock;
	COND_BLOCK		*condBlock;
	OBJVAR_BLOCK	*objVarBlock;
	ARRAY_BLOCK		*arrayBlock;
	PARAM_BLOCK		*pblock;
	PARAM_DECL		*pdecl;
	TRIGGER_DECL	*tdecl;
	UDWORD			integer_val;
	VAR_DECL		*vdecl;
	VAR_IDENT_DECL	*videcl;
}
	/* key words */
%token lexFUNCTION
%token TRIGGER
%token EVENT
%token WAIT
%token EVERY
%token INACTIVE
%token INITIALISE
%token LINK
%token REF
%token RET
%token _VOID

	/* %token COND */
%token WHILE
%token IF
%token ELSE
%token EXIT
%token PAUSE

	/* boolean operators */
%token BOOLEQUAL
%token NOTEQUAL
%token GREATEQUAL
%token LESSEQUAL
%token GREATER
%token LESS
%token _AND
%token _OR
%token _NOT
%token _INC
%token _DEC

%left _AND _OR
%left BOOLEQUAL NOTEQUAL GREATEQUAL LESSEQUAL GREATER LESS
%nonassoc _NOT
%left '-' '+' '&'
%left '*' '/'
%right TO_INT_CAST
%right TO_FLOAT_CAST
%nonassoc UMINUS
%left _INC _DEC

	/* value tokens */
%token <bval> BOOLEAN_T
%token <fval> FLOAT_T
%token <ival> INTEGER
%token <sval> QTEXT			/* Text with double quotes surrounding it */
%token <tval> TYPE			/* A type specifier */
%token <stype> STORAGE		/* Variable storage type */

%token <sval> IDENT			/* An undefined identifier */

%token <vSymbol> VAR		/* A defined variable */
%token <vSymbol> BOOL_VAR	/* A defined boolean variable */
%token <vSymbol> NUM_VAR	/* A defined numeric (int) variable */
%token <vSymbol> FLOAT_VAR	/* A defined numeric (float) variable */
%token <vSymbol> OBJ_VAR	/* A defined object pointer variable */
%token <vSymbol> STRING_VAR	/* A defined string variable */

%token <vSymbol> VAR_ARRAY		/* A defined variable array */
%token <vSymbol> BOOL_ARRAY		/* A defined boolean variable array */
%token <vSymbol> NUM_ARRAY		/* A defined numeric (int) variable array */
%token <vSymbol> FLOAT_ARRAY	/* A defined numeric (float) variable array */
%token <vSymbol> OBJ_ARRAY		/* A defined object pointer variable array */

%token <vSymbol> BOOL_OBJVAR	/* A defined boolean object member variable */
%token <vSymbol> NUM_OBJVAR		/* A defined numeric object member variable */
%token <vSymbol> USER_OBJVAR	/* A defined user type object member variable */
%token <vSymbol> OBJ_OBJVAR		/* A defined object pointer object member variable */

%token <cSymbol> BOOL_CONSTANT	/* A defined boolean constant */
%token <cSymbol> NUM_CONSTANT	/* A defined numeric constant */
%token <cSymbol> USER_CONSTANT	/* A defined object pointer constant */
%token <cSymbol> OBJ_CONSTANT	/* A defined object pointer constant */
%token <cSymbol> STRING_CONSTANT	/* A defined string constant */

%token <fSymbol> FUNC		/* A defined function */
%token <fSymbol> BOOL_FUNC	/* A defined boolean function */
%token <fSymbol> NUM_FUNC	/* A defined numeric (int) function */
%token <fSymbol> FLOAT_FUNC	/* A defined numeric (float) function */
%token <fSymbol> USER_FUNC	/* A defined user defined type function */
%token <fSymbol> OBJ_FUNC	/* A defined object pointer function */
%token <fSymbol> STRING_FUNC	/* A defined string function */

/* custom, in-script defined functions (events actually) */
%token <eSymbol> VOID_FUNC_CUST		/* A defined function */
%token <eSymbol> BOOL_FUNC_CUST	/* A defined boolean function */
%token <eSymbol> NUM_FUNC_CUST	/* A defined numeric (int) function */
%token <eSymbol> FLOAT_FUNC_CUST	/* A defined numeric (float) function */
%token <eSymbol> USER_FUNC_CUST	/* A defined user defined type function */
%token <eSymbol> OBJ_FUNC_CUST	/* A defined object pointer function */
%token <eSymbol> STRING_FUNC_CUST	/* A defined string function */


%token <tSymbol> TRIG_SYM	/* A defined trigger */
%token <eSymbol> EVENT_SYM	/* A defined event */
%token <cbSymbol> CALLBACK_SYM	/* A callback trigger */

	/* rule types */
%type <cblock> expression
%type <cblock> boolexp
%type <cblock> stringexp
%type <cblock> floatexp
%type <cblock> return_exp
%type <cblock> return_statement
%type <cblock> objexp
%type <cblock> objexp_dot
%type <cblock> userexp
%type <cblock> inc_dec_exp
%type <objVarBlock> num_objvar
%type <objVarBlock> bool_objvar
%type <objVarBlock> user_objvar
%type <objVarBlock> obj_objvar

%type <arrayBlock> array_index
%type <arrayBlock> array_index_list
%type <arrayBlock> num_array_var
%type <arrayBlock> bool_array_var
%type <arrayBlock> user_array_var
%type <arrayBlock> obj_array_var

%type <cblock> statement_list
%type <cblock> statement

%type <cblock> assignment

%type <cblock> func_call
%type <pblock> param_list
/* %type <pblock> braced_param_list */	/* for jump(), to make optional braced parameter list for function calls */
%type <pblock> parameter
%type <pblock> var_ref

%type <cblock> conditional
%type <condBlock> cond_clause
%type <condBlock> terminal_cond
%type <condBlock> cond_clause_list

%type <cblock> loop

%type <videcl>    array_sub_decl
%type <videcl>    array_sub_decl_list
%type <videcl>    variable_ident
%type <vdecl>     variable_decl_head
%type <vdecl>     variable_decl
%type <vdecl>     var_line
%type <tdecl>     trigger_subdecl
%type <integer_val> funcbody_var_def_body
%type <eSymbol> funcbody_var_def
%type <eSymbol> void_funcbody_var_def

/*%type <integer_val> func_decl_ret_type */	/* for function declarations and definitions */
%type <integer_val> funcvar_decl_types
%type <eSymbol>   event_subdecl
%type <eSymbol>   func_subdecl	/* function declaration */
%type <eSymbol>   function_def
%type <eSymbol>   void_function_def
%type <eSymbol>   void_func_subdecl	/* void function declaration */
%type <eSymbol>  function_declaration
%type <eSymbol>  void_function_declaration
%type <eSymbol> function_type

%%

/* 
  The final accepting rule, must always be the first 
  rule, if not explicitly defined as accepting rule
*/
accept_script:			script
				{
					unsigned int i, numArrays;
					SDWORD			size = 0, debug_i = 0, totalArraySize = 0;
					UDWORD			base;
					VAR_SYMBOL		*psCurr;
					TRIGGER_SYMBOL	*psTrig;
					EVENT_SYMBOL	*psEvent;
					UDWORD			numVars;

					RULE("script: var_list");

					// Calculate the code size
					for(psTrig = psTriggers; psTrig; psTrig = psTrig->psNext)
					{
						// Add the trigger code size
						size += psTrig->size;
						debug_i += psTrig->debugEntries;
					}

					for(psEvent = psEvents; psEvent; psEvent = psEvent->psNext)
					{
						// Add the trigger code size
						size += psEvent->size;
						debug_i += psEvent->debugEntries;
					}

					// Allocate the program
					numVars = psGlobalVars ? psGlobalVars->index+1 : 0;
					numArrays = psGlobalArrays ? psGlobalArrays->index+1 : 0;
					for(psCurr=psGlobalArrays; psCurr; psCurr=psCurr->psNext)
					{
						unsigned int arraySize = 1, dimension;
						for(dimension = 0; dimension < psCurr->dimensions; dimension++)
						{
							arraySize *= psCurr->elements[dimension];
						}
						totalArraySize += arraySize;
					}
					ALLOC_PROG(psFinalProg, size, psCurrBlock->pCode,
						numVars, numArrays, numTriggers, numEvents);

					//store local vars
					//allocate array for holding an array of local vars for each event
					psFinalProg->ppsLocalVars = (INTERP_TYPE **)malloc(sizeof(INTERP_TYPE*) * numEvents);
					psFinalProg->ppsLocalVarVal = NULL;
					psFinalProg->numLocalVars = (UDWORD *)malloc(sizeof(UDWORD) * numEvents);	//how many local vars each event has
					psFinalProg->numParams = (UDWORD *)malloc(sizeof(UDWORD) * numEvents);	//how many arguments each event has

					for(psEvent = psEvents, i = 0; psEvent; psEvent = psEvent->psNext, i++)
					{
						psEvent->numLocalVars = numEventLocalVars[i];

						psFinalProg->numLocalVars[i] = numEventLocalVars[i];	//remember how many local vars this event has
						psFinalProg->numParams[i] = psEvent->numParams;	//remember how many parameters this event has

						if(numEventLocalVars[i] > 0)
						{
							unsigned int j;
							INTERP_TYPE * pCurEvLocalVars = (INTERP_TYPE*)malloc(sizeof(INTERP_TYPE) * numEventLocalVars[i]);

							for(psCurr = psLocalVarsB[i], j = 0; psCurr != NULL; psCurr = psCurr->psNext, j++)
							{
								pCurEvLocalVars[numEventLocalVars[i] - j - 1] = psCurr->type;	//save type, order is reversed
							}

							psFinalProg->ppsLocalVars[i] = pCurEvLocalVars;
						}
						else
						{
							psFinalProg->ppsLocalVars[i] = NULL; //this event has no local vars
						}
					}

					ALLOC_DEBUG(psFinalProg, debug_i);
					psFinalProg->debugEntries = 0;
					ip = psFinalProg->pCode;

					// Add the trigger code
					for(psTrig = psTriggers, i = 0; psTrig; psTrig = psTrig->psNext, i++)
					{
						// Store the trigger offset
						psFinalProg->pTriggerTab[i] = (UWORD)(ip - psFinalProg->pCode);
						if (psTrig->pCode != NULL)
						{
							// Store the label
							DEBUG_LABEL(psFinalProg, psFinalProg->debugEntries,
								psTrig->pIdent);
							// Store debug info
							APPEND_DEBUG(psFinalProg, ip - psFinalProg->pCode, psTrig);
							// Store the code
							PUT_BLOCK(ip, psTrig);
							psFinalProg->psTriggerData[i].code = true;
						}
						else
						{
							psFinalProg->psTriggerData[i].code = false;
						}
						// Store the data
						psFinalProg->psTriggerData[i].type = (UWORD)psTrig->type;
						psFinalProg->psTriggerData[i].time = psTrig->time;
					}
					// Note the end of the final trigger
					psFinalProg->pTriggerTab[i] = (UWORD)(ip - psFinalProg->pCode);

					// Add the event code
					for(psEvent = psEvents, i = 0; psEvent; psEvent = psEvent->psNext, i++)
					{
						// Check the event was declared and has a code body
						if (psEvent->pCode == NULL)
						{
							scr_error("Event %s declared without being defined",
								psEvent->pIdent);
							YYABORT;
						}

						// Store the event offset
						psFinalProg->pEventTab[i] = (UWORD)(ip - psFinalProg->pCode);
						// Store the trigger link
						psFinalProg->pEventLinks[i] = (SWORD)(psEvent->trigger);
						// Store the label
						DEBUG_LABEL(psFinalProg, psFinalProg->debugEntries,
							psEvent->pIdent);
						// Store debug info
						APPEND_DEBUG(psFinalProg, ip - psFinalProg->pCode, psEvent);
						// Store the code
						PUT_BLOCK(ip, psEvent);
					}
					// Note the end of the final event
					psFinalProg->pEventTab[i] = (UWORD)(ip - psFinalProg->pCode);

					// Allocate debug info for the variables if necessary
					if (genDebugInfo)
					{
						if (numVars > 0)
						{
							psFinalProg->psVarDebug = malloc(sizeof(VAR_DEBUG) * numVars);
							if (psFinalProg->psVarDebug == NULL)
							{
								scr_error("Out of memory");
								YYABORT;
							}
						}
						else
						{
							psFinalProg->psVarDebug = NULL;
						}
						if (numArrays > 0)
						{
							psFinalProg->psArrayDebug = malloc(sizeof(ARRAY_DEBUG) * numArrays);
							if (psFinalProg->psArrayDebug == NULL)
							{
								scr_error("Out of memory");
								YYABORT;
							}
						}
						else
						{
							psFinalProg->psArrayDebug = NULL;
						}
					}
					else
					{
						psFinalProg->psVarDebug = NULL;
						psFinalProg->psArrayDebug = NULL;
					}

					/* Now set the types for the global variables */
					for(psCurr = psGlobalVars; psCurr != NULL; psCurr = psCurr->psNext)
					{
						unsigned int i = psCurr->index;
						psFinalProg->pGlobals[i] = psCurr->type;

						if (genDebugInfo)
						{
							psFinalProg->psVarDebug[i].pIdent = strdup(psCurr->pIdent);
							if (psFinalProg->psVarDebug[i].pIdent == NULL)
							{
								scr_error("Out of memory");
								YYABORT;
							}
							psFinalProg->psVarDebug[i].storage = psCurr->storage;
						}
					}

					/* Now store the array info */
					psFinalProg->arraySize = totalArraySize;
					for(psCurr = psGlobalArrays; psCurr != NULL; psCurr = psCurr->psNext)
					{
						unsigned int i = psCurr->index, dimension;

						psFinalProg->psArrayInfo[i].type = (UBYTE)psCurr->type;
						psFinalProg->psArrayInfo[i].dimensions = (UBYTE)psCurr->dimensions;
						for(dimension = 0; dimension < psCurr->dimensions; dimension++)
						{
							psFinalProg->psArrayInfo[i].elements[dimension] = (UBYTE)psCurr->elements[dimension];
						}

						if (genDebugInfo)
						{
							psFinalProg->psArrayDebug[i].pIdent = strdup(psCurr->pIdent);
							if (psFinalProg->psArrayDebug[i].pIdent == NULL)
							{
								scr_error("Out of memory");
								YYABORT;
							}
							psFinalProg->psArrayDebug[i].storage = psCurr->storage;
						}
					}
					// calculate the base index of each array
					base = psFinalProg->numGlobals;
					for(i=0; i<numArrays; i++)
					{
						unsigned int arraySize = 1, dimension;

						psFinalProg->psArrayInfo[i].base = base;
						for(dimension = 0; dimension < psFinalProg->psArrayInfo[i].dimensions; dimension++)
						{
							arraySize *= psFinalProg->psArrayInfo[i].elements[dimension];
						}

						base += arraySize;
					}

					RULE("END script: var_list");
				}
			;

script:					var_list trigger_list
						{
							RULE("script:var_list trigger_list");
						}
					|	script event_list
						{
							RULE("script:script event_list");
						}
					|	script var_list
						{
							RULE("script:script var_list");
						}
					|	script trigger_list
						{
							RULE("script:script trigger_list");
						}
					;

var_list:		/* NULL token */
				{
					RULE("var_list: NULL");
				}
			|	var_line
				{
					RULE("var_list: var_line");
					FREE_VARDECL($1);
				}
			|	var_list var_line
				{
					FREE_VARDECL($2);
				}
			;

	/**************************************************************************************
	 *
	 * Variable and function declarations
	 */

var_line:		variable_decl ';'
		{
			/* remember that local var declaration is over */
			localVariableDef = false;
			//debug(LOG_SCRIPT, "localVariableDef = false 0");
			$$ = $1;
		}
		;


variable_decl_head:		STORAGE TYPE
						{
							//debug(LOG_SCRIPT, "variable_decl_head:		STORAGE TYPE");

							ALLOC_VARDECL(psCurrVDecl);
							psCurrVDecl->storage = $1;
							psCurrVDecl->type = $2;

							/* allow local vars to have the same names as global vars (don't check global vars) */
							if($1 == ST_LOCAL)
							{
								localVariableDef = true;
								//debug(LOG_SCRIPT, "localVariableDef = true 0");
							}

							$$ = psCurrVDecl;
							//debug(LOG_SCRIPT, "END variable_decl_head:		STORAGE TYPE (TYPE=%d)", $2);
						}
					|	STORAGE	TRIGGER
						{

							ALLOC_VARDECL(psCurrVDecl);
							psCurrVDecl->storage = $1;
							psCurrVDecl->type = VAL_TRIGGER;

							$$ = psCurrVDecl;
						}
					|	STORAGE	EVENT
						{
							ALLOC_VARDECL(psCurrVDecl);
							psCurrVDecl->storage = $1;
							psCurrVDecl->type = VAL_EVENT;

							$$ = psCurrVDecl;
						}
					;

array_sub_decl:		'[' INTEGER ']'
					{
						if ($2 <= 0 || $2 >= VAR_MAX_ELEMENTS)
						{
							scr_error("Invalid array size %d", $2);
							YYABORT;
						}

						ALLOC_VARIDENTDECL(psCurrVIdentDecl, NULL, 1);
						psCurrVIdentDecl->elements[0] = $2;

						$$ = psCurrVIdentDecl;
					}
			;

array_sub_decl_list: array_sub_decl
					{
						$$ = $1;
					}
			|
					array_sub_decl_list '[' INTEGER ']'
					{
						if ($1->dimensions >= VAR_MAX_DIMENSIONS)
						{
							scr_error("Too many dimensions for array");
							YYABORT;
						}
						if ($3 <= 0 || $3 >= VAR_MAX_ELEMENTS)
						{
							scr_error("Invalid array size %d", $3);
							YYABORT;
						}

						$1->elements[$1->dimensions] = $3;
						$1->dimensions += 1;

						$$ = $1;
					}
			;

variable_ident:		IDENT
					{
						ALLOC_VARIDENTDECL(psCurrVIdentDecl, $1, 0);

						$$ = psCurrVIdentDecl;
					}
			|
					IDENT array_sub_decl_list
					{
						$2->pIdent = strdup($1);
						if ($2->pIdent == NULL)
						{
							scr_error("Out of memory");
							YYABORT;
						}

						$$ = $2;
					}
			;

variable_decl:	variable_decl_head variable_ident
					{
						if (!scriptAddVariable($1, $2))
						{
							/* Out of memory - error already given */
							YYABORT;
						}

						freeVARIDENTDECL($2);

						/* return the variable type */
						$$ = $1;
					}
			|	variable_decl ',' variable_ident
					{
						if (!scriptAddVariable($1, $3))
						{
							/* Out of memory - error already given */
							YYABORT;
						}

						freeVARIDENTDECL($3);

						/* return the variable type */
						$$ = $1;
					}
			;

	/**************************************************************************************
	 *
	 * Trigger declarations
	 */

trigger_list:		/* NULL token */
				|	trigger_decl
				|	trigger_list trigger_decl
				;

trigger_subdecl:	boolexp ',' INTEGER
					{
						ALLOC_TSUBDECL(psCurrTDecl, TR_CODE, $1->size, $3);
						ip = psCurrTDecl->pCode;
						PUT_BLOCK(ip, $1);
						FREE_BLOCK($1);

						$$ = psCurrTDecl;
					}
				|	WAIT ',' INTEGER
					{
						ALLOC_TSUBDECL(psCurrTDecl, TR_WAIT, 0, $3);

						$$ = psCurrTDecl;
					}
				|	EVERY ',' INTEGER
					{
						ALLOC_TSUBDECL(psCurrTDecl, TR_EVERY, 0, $3);

						$$ = psCurrTDecl;
					}
				|	INITIALISE
					{
						ALLOC_TSUBDECL(psCurrTDecl, TR_INIT, 0, 0);

						$$ = psCurrTDecl;
					}
				|	CALLBACK_SYM
					{
						if ($1->numParams != 0)
						{
							scr_error("Expected parameters for callback trigger");
							YYABORT;
						}

						ALLOC_TSUBDECL(psCurrTDecl, $1->type, 0, 0);

						$$ = psCurrTDecl;
					}
				|	CALLBACK_SYM ',' param_list
					{
						RULE("trigger_subdecl: CALLBACK_SYM ',' param_list");
						codeRet = scriptCodeCallbackParams($1, $3, &psCurrTDecl);
						CHECK_CODE_ERROR(codeRet);

						$$ = psCurrTDecl;
					}
				;

trigger_decl:		TRIGGER IDENT '(' trigger_subdecl ')' ';'
					{
						SDWORD	line;
						char	*pDummy;

						scriptGetErrorData(&line, &pDummy);
						if (!scriptAddTrigger($2, $4, (UDWORD)line))
						{
							YYABORT;
						}
						FREE_TSUBDECL($4);
					}
				;

	/**************************************************************************************
	 *
	 * Event declarations
	 */

event_list:			event_decl
				|	event_list event_decl
				;

event_subdecl:		EVENT IDENT
					{
						EVENT_SYMBOL	*psEvent;

						RULE("event_subdecl:		EVENT IDENT");

						if (!scriptDeclareEvent($2, &psEvent,0))
						{
							YYABORT;
						}

						psCurEvent = psEvent;

						$$ = psEvent;

						//debug(LOG_SCRIPT, "END event_subdecl:		EVENT IDENT");
					}
				|	EVENT EVENT_SYM
					{

						RULE("EVENT EVENT_SYM");

						psCurEvent = $2;
						$$ = $2;

						//debug(LOG_SCRIPT, "END EVENT EVENT_SYM");
					}
				;


function_def:		lexFUNCTION TYPE function_type
				{

					RULE("function_def: lexFUNCTION TYPE function_type");

					psCurEvent = $3;

					/* check if this event was declared as function before */
					if(!$3->bFunction)
					{
						debug(LOG_ERROR, "'%s' was declared as event before and can't be redefined to function", $3->pIdent);
						scr_error("Wrong event definition");
						YYABORT;
					}

					$$ = $3;
				}
			;

function_type:			VOID_FUNC_CUST
					|	BOOL_FUNC_CUST
					|	NUM_FUNC_CUST
					|	USER_FUNC_CUST
					|	OBJ_FUNC_CUST
					|	STRING_FUNC_CUST
					|	FLOAT_FUNC_CUST
					;

/* function declaration rules */
func_subdecl:		lexFUNCTION TYPE IDENT
					{
						EVENT_SYMBOL	*psEvent;

						RULE("func_subdecl: lexFUNCTION TYPE IDENT");

						/* allow local vars to have the same names as global vars (don't check global vars) */
						localVariableDef = true;
						//debug(LOG_SCRIPT, "localVariableDef = true 1");

						if (!scriptDeclareEvent($3, &psEvent,0))
						{
							YYABORT;
						}

						psEvent->retType = $2;
						psCurEvent = psEvent;
						psCurEvent->bFunction = true;

						$$ = psEvent;

						//debug(LOG_SCRIPT, "END func_subdecl:lexFUNCTION TYPE IDENT. ");
					}
				;


/* void function declaration rules */
void_func_subdecl:		lexFUNCTION _VOID IDENT	/* declaration of a function */
						{
							EVENT_SYMBOL	*psEvent;

							RULE("void_func_subdecl: lexFUNCTION _VOID IDENT");

							/* allow local vars to have the same names as global vars (don't check global vars) */
							localVariableDef = true;
							//debug(LOG_SCRIPT, "localVariableDef = true 1");

							if (!scriptDeclareEvent($3, &psEvent,0))
							{
								YYABORT;
							}

							psEvent->retType = VAL_VOID;
							psCurEvent = psEvent;
							psCurEvent->bFunction = true;

							$$ = psEvent;

							//debug(LOG_SCRIPT, "END func_subdecl:lexFUNCTION TYPE IDENT. ");
						}
					;

void_function_def:		lexFUNCTION _VOID function_type	/* definition of a function that was declated before */
						{
							//debug(LOG_SCRIPT, "func_subdecl:lexFUNCTION EVENT_SYM ");
							psCurEvent = $3;


							/* check if this event was declared as function before */
							if(!$3->bFunction)
							{
								debug(LOG_ERROR, "'%s' was declared as event before and can't be redefined to function", $3->pIdent);
								scr_error("Wrong event definition");
								YYABORT;
							}

							/* psCurEvent->bFunction = true; */
							/* psEvent->retType = $2; */
							$$ = $3;
							//debug(LOG_SCRIPT, "func_subdecl:lexFUNCTION EVENT_SYM. ");
						}
					;



funcvar_decl_types:		TYPE NUM_VAR
						{
							$$=$1;
						}
					|	TYPE FLOAT_VAR
						{
							$$=$1;
						}
					|	TYPE BOOL_VAR
						{
							$$=$1;
						}
					|	TYPE STRING_VAR
						{
							$$=$1;
						}
					|	TYPE OBJ_VAR
						{
							$$=$1;
						}
					|	TYPE OBJ_OBJVAR
						{
							$$=$1;
						}
					|	TYPE OBJ_ARRAY
						{
							$$=$1;
						}
					|	TYPE VAR	/* STRUCTURESTAT, RESEARCHSTAT etc */
						{
							$$=$1;
						}
					;


funcbody_var_def_body:		 funcvar_decl_types
				{
					if(!checkFuncParamType(0, $1))
					{
						scr_error("Wrong event argument definition in '%s'", psCurEvent->pIdent);
						YYABORT;
					}

					//debug(LOG_SCRIPT, "funcbody_var_def_body=%d \n", $1);
					$$=1;
				}
			| funcbody_var_def_body ',' funcvar_decl_types
				{
					if(!checkFuncParamType($1, $3))
					{
						scr_error("Wrong event argument definition");
						YYABORT;
					}

					//debug(LOG_SCRIPT, "funcbody_var_def_body2=%d \n", $3);
					$$=$1+1;
				}
			;

	/* function was declared before */
funcbody_var_def:	function_def '(' funcbody_var_def_body ')'
					{

						RULE("funcbody_var_def: '(' funcvar_decl_types ')'");

						/* remember that local var declaration is over */
						localVariableDef = false;

						if(psCurEvent == NULL)
						{
							scr_error("psCurEvent == NULL");
							YYABORT;
						}

						if(!psCurEvent->bDeclared)
						{
							debug(LOG_ERROR, "Event %s's definition doesn't match with declaration.", psCurEvent->pIdent);
							scr_error("Wrong event definition:\n event %s's definition doesn't match with declaration", psCurEvent->pIdent);
							YYABORT;
						}

						/* check if number of parameter in body defenition match number of params in the declaration */
						if($3 != psCurEvent->numParams)
						{
							scr_error("Wrong number of arguments in function definition (or declaration-definition argument type/names mismatch) \n in event: '%s'", psCurEvent->pIdent);
							YYABORT;
						}

						$$ = $1;
					}
				|	function_def '(' ')'
					{

						RULE( "funcbody_var_def: funcbody_var_def_body '(' ')'");

						/* remember that local var declaration is over */
						localVariableDef = false;

						if(psCurEvent == NULL)
						{
							scr_error("psCurEvent == NULL");
							YYABORT;
						}

						if(!psCurEvent->bDeclared)
						{
							debug(LOG_ERROR, "Event %s's definition doesn't match with declaration.", psCurEvent->pIdent);
							scr_error("Wrong event definition:\n event %s's definition doesn't match with declaration", psCurEvent->pIdent);
							YYABORT;
						}

						/* check if number of parameter in body defenition match number of params in the declaration */
						if(0 != psCurEvent->numParams)
						{
							scr_error("Wrong number of arguments in function definition (or declaration-definition argument type/names mismatch) \n in event: '%s'", psCurEvent->pIdent);
							YYABORT;
						}

						$$ = $1;
					}

				;


	/* void function was declared before */
void_funcbody_var_def:	void_function_def '(' funcbody_var_def_body ')'
					{

						RULE( "funcbody_var_def: '(' funcvar_decl_types ')'");

						/* remember that local var declaration is over */
						localVariableDef = false;

						if(psCurEvent == NULL)
						{
							scr_error("psCurEvent == NULL");
							YYABORT;
						}

						if(!psCurEvent->bDeclared)
						{
							debug(LOG_ERROR, "Event %s's definition doesn't match with declaration.", psCurEvent->pIdent);
							scr_error("Wrong event definition:\n event %s's definition doesn't match with declaration", psCurEvent->pIdent);
							YYABORT;
						}

						/* check if number of parameter in body defenition match number of params in the declaration */
						if($3 != psCurEvent->numParams)
						{
							scr_error("Wrong number of arguments in function definition (or declaration-definition argument type/names mismatch) \n in event: '%s'", psCurEvent->pIdent);
							YYABORT;
						}

						$$ = $1;
					}
				|	void_function_def '(' ')'
					{

						RULE( "funcbody_var_def: funcbody_var_def_body '(' ')'");

						/* remember that local var declaration is over */
						localVariableDef = false;

						if(psCurEvent == NULL)
						{
							scr_error("psCurEvent == NULL");
							YYABORT;
						}

						if(!psCurEvent->bDeclared)
						{
							debug(LOG_ERROR, "Event %s's definition doesn't match with declaration.", psCurEvent->pIdent);
							scr_error("Wrong event definition:\n event %s's definition doesn't match with declaration", psCurEvent->pIdent);
							YYABORT;
						}

						/* check if number of parameter in body defenition match number of params in the declaration */
						if(0 != psCurEvent->numParams)
						{
							scr_error("Wrong number of arguments in function definition (or declaration-definition argument type/names mismatch) \n in event: '%s'", psCurEvent->pIdent);
							YYABORT;
						}

						$$ = $1;
					}

				;


/* event declaration with parameters, like: event myEvent(int Arg1, string Arg2); */
argument_decl_head:		TYPE variable_ident
				{

					RULE( "argument_decl_head: TYPE variable_ident");


					/* handle type part */
					ALLOC_VARDECL(psCurrVDecl);
					psCurrVDecl->storage =ST_LOCAL;	/* can only be local */
					psCurrVDecl->type = $1;

					/* handle ident part */
					if (!scriptAddVariable(psCurrVDecl, $2))
					{
						YYABORT;
					}

					freeVARIDENTDECL($2);

					FREE_VARDECL(psCurrVDecl);

					/* return the variable type */
					/* $$ = psCurrVDecl; */ /* not needed? */

					if(psCurEvent == NULL)
						debug(LOG_ERROR, "argument_decl_head 0:  - psCurEvent == NULL");

					psCurEvent->numParams = psCurEvent->numParams + 1;	/* remember a parameter was declared */

					/* remember parameter type */
					psCurEvent->aParams[0] = $1;

					//debug(LOG_SCRIPT, "argument_decl_head 0. ");
				}
			|	argument_decl_head ',' TYPE variable_ident
				{
					//debug(LOG_SCRIPT, "argument_decl_head 1 ");

					/* handle type part */
					ALLOC_VARDECL(psCurrVDecl);
					psCurrVDecl->storage =ST_LOCAL;	/* can only be local */
					psCurrVDecl->type = $3;

					/* remember parameter type */
					psCurEvent->aParams[psCurEvent->numParams] = $3;
					//debug(LOG_SCRIPT, "argument_decl_head 10 ");

					/* handle ident part */
					if (!scriptAddVariable(psCurrVDecl, $4))
					{
						YYABORT;
					}
					//debug(LOG_SCRIPT, "argument_decl_head 11 ");
					freeVARIDENTDECL($4);
					FREE_VARDECL(psCurrVDecl);

					/* return the variable type */
					/* $$ = psCurrVDecl; */ /* not needed? */

					if(psCurEvent == NULL)
						debug(LOG_ERROR, "argument_decl_head 0:  - psCurEvent == NULL");
					psCurEvent->numParams = psCurEvent->numParams + 1;	/* remember a parameter was declared */

					//debug(LOG_SCRIPT, "argument_decl_head 1. ");
				}
			;
argument_decl:	'(' ')'
			|	'(' argument_decl_head ')'
				{
					/* remember that local var declaration is over */
					localVariableDef = false;
					//debug(LOG_SCRIPT, "localVariableDef = false 1");
				}
			;

function_declaration:		func_subdecl '(' argument_decl_head ')'	/* function was not declared before */
				{
					RULE( "function_declaration: func_subdecl '(' argument_decl_head ')'");

					/* remember that local var declaration is over */
					localVariableDef = false;
					//debug(LOG_SCRIPT, "localVariableDef = false 2");

					if(psCurEvent->bDeclared) /* can only occur if different (new) var names are used in the event definition that don't match with declaration*/
					{
						scr_error("Wrong event definition: \nEvent %s's definition doesn't match with declaration", psCurEvent->pIdent);
						YYABORT;
					}

					$$ = $1;
				}
			|	func_subdecl '(' ')'
				{
					RULE( "function_declaration: func_subdecl '(' ')'");

					/* remember that local var declaration is over */
					localVariableDef = false;
					//debug(LOG_SCRIPT, "localVariableDef = false 3");

					if($1->numParams > 0 && psCurEvent->bDeclared) /* can only occur if no parameters or different (new) var names are used in the event definition that don't match with declaration */
					{
						scr_error("Wrong event definition: \nEvent %s's definition doesn't match with declaration", psCurEvent->pIdent);
						YYABORT;
					}

					$$ = $1;
				}

			;



void_function_declaration:		void_func_subdecl '(' argument_decl_head ')'	/* function was not declared before */
				{
					/* remember that local var declaration is over */
					localVariableDef = false;
					//debug(LOG_SCRIPT, "localVariableDef = false 2");

					if(psCurEvent->bDeclared) /* can only occur if different (new) var names are used in the event definition that don't match with declaration*/
					{
						scr_error("Wrong event definition: \nEvent %s's definition doesn't match with declaration", psCurEvent->pIdent);
						YYABORT;
					}

					$$ = $1;
				}
			|	void_func_subdecl '(' ')'
				{

						RULE( "void_function_declaration: void_func_subdecl '(' ')'");

					/* remember that local var declaration is over */
					localVariableDef = false;
					//debug(LOG_SCRIPT, "localVariableDef = false 3");

					if($1->numParams > 0 && psCurEvent->bDeclared) /* can only occur if no parameters or different (new) var names are used in the event definition that don't match with declaration */
					{
						scr_error("Wrong event definition: \nEvent %s's definition doesn't match with declaration", psCurEvent->pIdent);
						YYABORT;
					}

					$$ = $1;
				}

			;


return_statement_void:	RET ';'
			;

return_statement:	return_statement_void
					{

						RULE( "return_statement: return_statement_void");

						if(psCurEvent == NULL)	/* no events declared or defined yet */
						{
							scr_error("return statement outside of function");
							YYABORT;
						}

						if(!psCurEvent->bFunction)
						{
							scr_error("return statement inside of an event '%s'", psCurEvent->pIdent);
							YYABORT;
						}

						if(psCurEvent->retType != VAL_VOID)
						{
							scr_error("wrong return statement syntax for a non-void function '%s'", psCurEvent->pIdent);
							YYABORT;
						}

						/* Allocate code block for exit instruction */
						ALLOC_BLOCK(psCurrBlock, 1);	//1 for opcode
						ip = psCurrBlock->pCode;
						PUT_OPCODE(ip, OP_EXIT);

						psCurrBlock->type = VAL_VOID;	/* make return statement of type VOID manually */

						$$ = psCurrBlock;
					}
					|	RET  return_exp  ';'
					{

						RULE( "return_statement: RET return_exp ';'");

						if(psCurEvent == NULL)	/* no events declared or defined yet */
						{
							debug(LOG_ERROR, "return statement outside of function");
							YYABORT;
						}

						if(!psCurEvent->bFunction)
						{
							debug(LOG_ERROR, "return statement inside of an event '%s'", psCurEvent->pIdent);
							YYABORT;
						}

						if(psCurEvent->retType != $2->type)
						{
							if(!interpCheckEquiv(psCurEvent->retType, $2->type))
							{
								debug(LOG_ERROR, "return type mismatch");
								debug(LOG_ERROR, "wrong return statement syntax for function '%s' (%d - %d)", psCurEvent->pIdent, psCurEvent->retType, $2->type);
								YYABORT;
							}
						}

						/* Allocate code block for exit instruction */
						ALLOC_BLOCK(psCurrBlock, $2->size + 1);	//+1 for OPCODE

						ip = psCurrBlock->pCode;

						PUT_BLOCK(ip, $2);

						PUT_OPCODE(ip, OP_EXIT);

						/* store the type of the exp */
						psCurrBlock->type = $2->type;
						
						FREE_BLOCK($2);

						$$ = psCurrBlock;

						//debug(LOG_SCRIPT, "END RET  return_exp  ';'");
					}
			;


statement_list:		/* NULL token */
						{
							RULE( "statement_list: NULL");

							// Allocate a dummy code block
							ALLOC_BLOCK(psCurrBlock, 1);
							psCurrBlock->size = 0;

							$$ = psCurrBlock;
						}
				|	statement
						{
							RULE("statement_list: statement");
							$$ = $1;
						}
				|	statement_list statement
						{
							RULE("statement_list: statement_list statement");

							ALLOC_BLOCK(psCurrBlock, $1->size + $2->size);

							ALLOC_DEBUG(psCurrBlock, $1->debugEntries +
													 $2->debugEntries);
							ip = psCurrBlock->pCode;

							/* Copy the two code blocks */
							PUT_BLOCK(ip, $1);
							PUT_BLOCK(ip, $2);
							PUT_DEBUG(psCurrBlock, $1);
							APPEND_DEBUG(psCurrBlock, $1->size / sizeof(INTERP_VAL), $2);

							ASSERT($1 != NULL, "$1 == NULL");
							ASSERT($1->psDebug != NULL, "psDebug == NULL");

							FREE_DEBUG($1);
							FREE_DEBUG($2);
							FREE_BLOCK($1);
							FREE_BLOCK($2);

							/* Return the code block */
							$$ = psCurrBlock;
						}
				;


event_decl:			event_subdecl ';'
					{
						RULE( "event_decl: event_subdecl ';'");

						psCurEvent->bDeclared = true;
					}
				|	func_subdecl argument_decl ';'	/* event (function) declaration can now include parameter declaration (optional) */
					{
						//debug(LOG_SCRIPT, "localVariableDef = false new ");
						localVariableDef = false;
						psCurEvent->bDeclared = true;
					}
				|	void_func_subdecl argument_decl ';'	/* event (function) declaration can now include parameter declaration (optional) */
					{
						RULE( "event_decl: void_func_subdecl argument_decl ';'");

						//debug(LOG_SCRIPT, "localVariableDef = false new ");
						localVariableDef = false;
						psCurEvent->bDeclared = true;
					}
				|	event_subdecl '(' TRIG_SYM ')' '{' var_list statement_list '}' 	/* 16.08.05 - local vars support */
					{
						RULE( "event_decl: event_subdecl '(' TRIG_SYM ')'");

						/* make sure this event is not declared as function */
						if(psCurEvent->bFunction)
						{
							debug(LOG_ERROR, "Event '%s' is declared as function and can't have a trigger assigned", psCurEvent->pIdent);
							scr_error("Wrong event definition");
							YYABORT;
						}

						/* pop required number of paramerets passed to this event (if any) */
						/* popArguments($1, $7, &psCurrBlock); */

						/* if (!scriptDefineEvent($1, $6, $3->index)) */
						if (!scriptDefineEvent($1, $7, $3->index))
						{
							YYABORT;
						}

						/* end of event */
						psCurEvent = NULL;

						FREE_DEBUG($7);
						FREE_BLOCK($7);

						RULE( "END event_decl: event_subdecl '(' TRIG_SYM ')'");

					}
				|	event_subdecl '(' trigger_subdecl ')'
					{
						// Get the line for the implicit trigger declaration
						char	*pDummy;

						RULE( "event_decl:event_subdecl '(' trigger_subdecl ')' ");

						/* make sure this event is not declared as function */
						if(psCurEvent->bFunction)
						{
							debug(LOG_ERROR, "Event '%s' is declared as function and can't have a trigger assigned", psCurEvent->pIdent);
							scr_error("Wrong event definition");
							YYABORT;
						}

						scriptGetErrorData((SDWORD *)&debugLine, &pDummy);
					}
				'{' var_list statement_list '}'	/* local vars support */
					{
						RULE("event_decl: '{' var_list statement_list '}'");

						// Create a trigger for this event
						if (!scriptAddTrigger("", $3, debugLine))
						{
							YYABORT;
						}
						FREE_TSUBDECL($3);

						/* if (!scriptDefineEvent($1, $7, numTriggers - 1)) */
						if (!scriptDefineEvent($1, $8, numTriggers - 1))
						{
							YYABORT;
						}

						/* end of event */
						psCurEvent = NULL;

						FREE_DEBUG($8);
						FREE_BLOCK($8);

						RULE( "END event_decl:event_subdecl '(' trigger_subdecl ')' .");
					}

				/* local vars */
				|	event_subdecl '(' INACTIVE ')' '{' var_list statement_list '}'
					{
						RULE( "event_subdecl '(' INACTIVE ')' '{' var_list statement_list '}'");

						/* make sure this event is not declared as function */
						if(psCurEvent->bFunction)
						{
							debug(LOG_ERROR, "Event '%s' is declared as function and can't have a trigger assigned", psCurEvent->pIdent);
							scr_error("Wrong event definition");
							YYABORT;
						}

						if (!scriptDefineEvent($1, $7, -1))
						{
							YYABORT;
						}

						/* end of event */
						psCurEvent = NULL;

						FREE_DEBUG($7);
						FREE_BLOCK($7);

						RULE( "END event_subdecl '(' INACTIVE ')' '{' var_list statement_list '}'");
					}

				/* VOID function that was NOT declared before */
				|	void_function_declaration  '{' var_list statement_list  '}'
					{
						RULE( "void_function_declaration  '{' var_list statement_list  '}'");

						/* stays the same if no params (just gets copied) */
						ALLOC_BLOCK(psCurrBlock, $4->size + 1 + $1->numParams); /* statement_list + opcode + numParams */
						ip = psCurrBlock->pCode;

						/* pop required number of paramerets passed to this event (if any) */
						popArguments(&ip, $1->numParams);

						/* Copy the two code blocks */
						PUT_BLOCK(ip, $4);
						PUT_OPCODE(ip, OP_EXIT);		/* must exit after return */

						ALLOC_DEBUG(psCurrBlock, $4->debugEntries);
						PUT_DEBUG(psCurrBlock, $4);

						if (!scriptDefineEvent($1, psCurrBlock, -1))
						{
							YYABORT;
						}

						FREE_DEBUG($4);
						FREE_BLOCK($4);

						/* end of event */
						psCurEvent = NULL;

						/* free block since code was copied in scriptDefineEvent() */
						FREE_DEBUG(psCurrBlock);
						FREE_BLOCK(psCurrBlock);

						RULE( "END void_function_declaration  '{' var_list statement_list  '}'");
					}

					/* void function that was declared before */
				 |	void_funcbody_var_def '{' var_list statement_list '}'
					{

						RULE( "void_funcbody_var_def '{' var_list statement_list '}'");

						/* stays the same if no params (just gets copied) */
						ALLOC_BLOCK(psCurrBlock, $4->size + 1 + $1->numParams);	/* statements + opcode + numparams */
						ip = psCurrBlock->pCode;

						/* pop required number of paramerets passed to this event (if any) */
						popArguments(&ip, $1->numParams);

						/* Copy the old (main) code and free it */
						PUT_BLOCK(ip, $4);
						PUT_OPCODE(ip, OP_EXIT);		/* must exit after return */

						/* copy debug info */
						ALLOC_DEBUG(psCurrBlock, $4->debugEntries);
						PUT_DEBUG(psCurrBlock, $4);

						if (!scriptDefineEvent($1, psCurrBlock, -1))
						{
							YYABORT;
						}

						FREE_DEBUG($4);
						FREE_BLOCK($4);
						FREE_DEBUG(psCurrBlock);
						FREE_BLOCK(psCurrBlock);

						/* end of event */
						psCurEvent = NULL;

						RULE( "END void_func_subdecl '(' funcbody_var_def_body ')' '{' var_list statement_list '}'");
					}

				/* function that was NOT declared before (atleast must look like this)!!! */
				|	function_declaration  '{' var_list statement_list return_statement  '}'
					{
						RULE( "function_declaration  '{' var_list statement_list return_statement  '}'");

						/* stays the same if no params (just gets copied) */
						//ALLOC_BLOCK(psCurrBlock, $4->size + $5->size + sizeof(OPCODE) + (sizeof(OPCODE) * $1->numParams)); /* statement_list + expression + EXIT + numParams */
						ALLOC_BLOCK(psCurrBlock, $4->size + $5->size + 1 + $1->numParams); /* statement_list + return_expr + EXIT opcode + numParams */
						ip = psCurrBlock->pCode;

						/* pop required number of paramerets passed to this event (if any) */
						popArguments(&ip, $1->numParams);

						/* Copy the two code blocks */
						PUT_BLOCK(ip, $4);

						PUT_BLOCK(ip, $5);

						PUT_OPCODE(ip, OP_EXIT);		/* must exit after return */

						ALLOC_DEBUG(psCurrBlock, $4->debugEntries);

						PUT_DEBUG(psCurrBlock, $4);

						if (!scriptDefineEvent($1, psCurrBlock, -1))
						{
							YYABORT;
						}

						FREE_DEBUG($4);
						FREE_BLOCK($4);
						FREE_BLOCK($5);

						/* end of event */
						psCurEvent = NULL;

						/* free block since code was copied in scriptDefineEvent() */
						FREE_DEBUG(psCurrBlock);
						FREE_BLOCK(psCurrBlock);

						RULE( "END function_declaration  '{' var_list statement_list return_statement  '}'");
					}

				/* function that WAS declared before */
				|	funcbody_var_def '{' var_list statement_list return_statement '}'
					{
						RULE( "func_subdecl '(' funcbody_var_def_body ')' '{' var_list statement_list return_statement '}'");

						/* stays the same if no params (just gets copied) */
						//ALLOC_BLOCK(psCurrBlock, $4->size + $5->size + sizeof(OPCODE) + (sizeof(OPCODE) * $1->numParams));
						ALLOC_BLOCK(psCurrBlock, $4->size + $5->size + 1 + $1->numParams);	/* statements + return expr + opcode + numParams */
						ip = psCurrBlock->pCode;

						/* pop required number of paramerets passed to this event (if any) */
						popArguments(&ip, $1->numParams);

						/* Copy the old (main) code and free it */
						PUT_BLOCK(ip, $4);
						PUT_BLOCK(ip, $5);
						PUT_OPCODE(ip, OP_EXIT);		/* must exit after return */

						/* copy debug info */
						ALLOC_DEBUG(psCurrBlock, $4->debugEntries);
						PUT_DEBUG(psCurrBlock, $4);

						RULE( "debug entries %d", $4->debugEntries);

						if (!scriptDefineEvent($1, psCurrBlock, -1))
						{
							YYABORT;
						}

						FREE_DEBUG($4);
						FREE_BLOCK($4);
						FREE_BLOCK($5);
						FREE_DEBUG(psCurrBlock);
						FREE_BLOCK(psCurrBlock);

						/* end of event */
						psCurEvent = NULL;

						RULE( "END func_subdecl '(' funcbody_var_def_body ')' '{' var_list statement_list return_statement '}'");
					}

				/* function that WAS declared before with a single return statement  */
				|	funcbody_var_def '{' var_list return_statement '}'
					{
						RULE( "funcbody_var_def '{' var_list return_statement '}'");

						/* stays the same if no params (just gets copied) */
						ALLOC_BLOCK(psCurrBlock, $4->size + 1 + $1->numParams);	/*  return expr + opcode + numParams */
						ip = psCurrBlock->pCode;

						/* pop required number of paramerets passed to this event (if any) */
						popArguments(&ip, $1->numParams);

						/* Copy the old (main) code and free it */
						PUT_BLOCK(ip, $4);
						PUT_OPCODE(ip, OP_EXIT);		/* must exit after return */

						if (!scriptDefineEvent($1, psCurrBlock, -1))
						{
							YYABORT;
						}

						FREE_BLOCK($4);
						FREE_BLOCK(psCurrBlock);
						psCurEvent = NULL;

						RULE( "END funcbody_var_def '{' var_list return_statement '}'");
					}
				/* function with a single return statement that was NOT declared before */
				|	function_declaration '{' var_list return_statement  '}'
					{
						RULE( "function_declaration  '{' var_list statement_list return_statement  '}'");

						/* stays the same if no params (just gets copied) */
						ALLOC_BLOCK(psCurrBlock, $4->size + 1 + $1->numParams); /* return_expr + EXIT opcode + numParams */
						ip = psCurrBlock->pCode;

						/* pop required number of paramerets passed to this event (if any) */
						popArguments(&ip, $1->numParams);

						/* Copy code block */
						PUT_BLOCK(ip, $4);
						PUT_OPCODE(ip, OP_EXIT);		/* must exit after return */

						if (!scriptDefineEvent($1, psCurrBlock, -1))
						{
							YYABORT;
						}

						FREE_BLOCK($4);
						psCurEvent = NULL;
						FREE_BLOCK(psCurrBlock);

						RULE( "END function_declaration  '{' var_list statement_list return_statement  '}'");
					}
				;

	/**************************************************************************************
	 *
	 * Statements
	 */

statement:			assignment ';'
					{
						UDWORD line;
						char *pDummy;

						RULE("statement: assignment");

						/* Put in debugging info */
						if (genDebugInfo)
						{
							ALLOC_DEBUG($1, 1);
							$1->psDebug[0].offset = 0;
							scriptGetErrorData((SDWORD *)&line, &pDummy);
							$1->psDebug[0].line = line;
						}

						$$ = $1;
					}
				|	inc_dec_exp ';'
					{
						UDWORD line;
						char *pDummy;

						RULE("statement: inc_dec_exp");

						/* Put in debugging info */
						if (genDebugInfo)
						{
							ALLOC_DEBUG($1, 1);
							$1->psDebug[0].offset = 0;
							scriptGetErrorData((SDWORD *)&line, &pDummy);
							$1->psDebug[0].line = line;
						}

						$$ = $1;
					}
				|	func_call ';'
					{
						UDWORD line;
						char *pDummy;

						RULE("statement: func_call ';'");

						/* Put in debugging info */
						if (genDebugInfo)
						{
							ALLOC_DEBUG($1, 1);
							$1->psDebug[0].offset = 0;
							scriptGetErrorData((SDWORD *)&line, &pDummy);
							$1->psDebug[0].line = line;
						}

						$$ = $1;
					}
			|	VOID_FUNC_CUST '(' param_list ')'  ';'
					{
						UDWORD line,paramNumber;
						char *pDummy;

						RULE( "statement: VOID_FUNC_CUST '(' param_list ')'  ';'");

						/* allow to call EVENTs to reuse the code only if no actual parameters are specified in function call, like "myEvent();" */
						if(!$1->bFunction && $3->numParams > 0)
						{
							scr_error("Can't pass any parameters in an event call:\nEvent: '%s'", $1->pIdent);
							return CE_PARSE;
						}

						if($3->numParams != $1->numParams)
						{
							scr_error("Wrong number of arguments for function call: '%s'. Expected %d parameters instead of  %d.", $1->pIdent, $1->numParams, $3->numParams);
							return CE_PARSE;
						}

						/* check if right parameters were passed */
						paramNumber = checkFuncParamTypes($1, $3);
						if(paramNumber > 0)
						{
							debug(LOG_ERROR, "Parameter mismatch in function call: '%s'. Mismatch in parameter  %d.", $1->pIdent, paramNumber);
							YYABORT;
						}

						/* Allocate the code block */
						ALLOC_BLOCK(psCurrBlock, $3->size + 1 + 1);	//paramList + opcode + event index
						ALLOC_DEBUG(psCurrBlock, 1);
						ip = psCurrBlock->pCode;

						if($3->numParams > 0)	/* if any parameters declared */
						{
							/* Copy in the code for the parameters */
							PUT_BLOCK(ip, $3);
						}

						FREE_PBLOCK($3);

						/* Store the instruction */
						PUT_OPCODE(ip, OP_FUNC);
						PUT_EVENT(ip,$1->index);			//Put event index

						/* Add the debugging information */
						if (genDebugInfo)
						{
							psCurrBlock->psDebug[0].offset = 0;
							scriptGetErrorData((SDWORD *)&line, &pDummy);
							psCurrBlock->psDebug[0].line = line;
						}

						$$ = psCurrBlock;
					}
			|	EVENT_SYM '(' param_list ')'  ';'		/* event as a void function to reuse the code */
					{
						UDWORD line;
						char *pDummy;

						RULE( "statement: EVENT_SYM '(' param_list ')'  ';'");

						/* allow to call EVENTs to reuse the code only if no actual parameters are specified in function call, like "myEvent();" */
						if(!$1->bFunction && $3->numParams > 0)
						{
							scr_error("Can't pass any parameters in an event call:\nEvent: '%s'", $1->pIdent);
							return CE_PARSE;
						}

						if($3->numParams != $1->numParams)
						{
							scr_error("Wrong number of arguments for function call: '%s'. Expected %d parameters instead of  %d.", $1->pIdent, $1->numParams, $3->numParams);
							return CE_PARSE;
						}

						/* Allocate the code block */
						//ALLOC_BLOCK(psCurrBlock, $3->size + sizeof(OPCODE) + sizeof(UDWORD));	//Params + Opcode + event index
						ALLOC_BLOCK(psCurrBlock, $3->size + 1 + 1);	//Params + Opcode + event index
						ALLOC_DEBUG(psCurrBlock, 1);
						ip = psCurrBlock->pCode;

						if($3->numParams > 0)	/* if any parameters declared */
						{
							/* Copy in the code for the parameters */
							PUT_BLOCK(ip, $3);
						}

						FREE_PBLOCK($3);

							/* Store the instruction */
						PUT_OPCODE(ip, OP_FUNC);
						PUT_EVENT(ip,$1->index);			//Put event index as VAL_EVENT

						/* Add the debugging information */
						if (genDebugInfo)
						{
							psCurrBlock->psDebug[0].offset = 0;
							scriptGetErrorData((SDWORD *)&line, &pDummy);
							psCurrBlock->psDebug[0].line = line;
						}

						$$ = psCurrBlock;
					}
				|	conditional
					{
						$$ = $1;
					}
				|	loop
					{
						$$ = $1;
					}
				|	EXIT ';'
					{
						UDWORD line;
						char *pDummy;

						/* Allocate the code block */
						ALLOC_BLOCK(psCurrBlock, 1);	//1 - Exit opcode
						ALLOC_DEBUG(psCurrBlock, 1);
						ip = psCurrBlock->pCode;

						/* Store the instruction */
						PUT_OPCODE(ip, OP_EXIT);

						/* Add the debugging information */
						if (genDebugInfo)
						{
							psCurrBlock->psDebug[0].offset = 0;
							scriptGetErrorData((SDWORD *)&line, &pDummy);
							psCurrBlock->psDebug[0].line = line;
						}

						$$ = psCurrBlock;
					}
				|	return_statement
					{
						UDWORD line;
						char *pDummy;

						RULE( "statement: return_statement");

						if(psCurEvent == NULL)
						{
							scr_error("'return' outside of function body");
							YYABORT;
						}

						if(!psCurEvent->bFunction)
						{
							debug(LOG_ERROR, "'return' can only be used in functions, not in events, event: '%s'", psCurEvent->pIdent);
							scr_error("'return' in event");
							YYABORT;
						}

						if($1->type != psCurEvent->retType)
						{
							debug(LOG_ERROR, "'return' type doesn't match with function return type, function: '%s' (%d / %d)", psCurEvent->pIdent, $1->type, psCurEvent->retType);
							scr_error("'return' type mismatch 0");
							YYABORT;
						}

						ALLOC_BLOCK(psCurrBlock, $1->size + 1);	//return statement + EXIT opcode
						ALLOC_DEBUG(psCurrBlock, 1);
						ip = psCurrBlock->pCode;

						PUT_BLOCK(ip, $1);
						PUT_OPCODE(ip, OP_EXIT);

						FREE_BLOCK($1);

						if (genDebugInfo)
						{
							psCurrBlock->psDebug[0].offset = 0;
							scriptGetErrorData((SDWORD *)&line, &pDummy);
							psCurrBlock->psDebug[0].line = line;
						}

						$$ = psCurrBlock;
					}
				|	PAUSE '(' INTEGER ')' ';'
					{
						UDWORD line;
						char *pDummy;

						// can only have a positive pause
						if ($3 < 0)
						{
							scr_error("Invalid pause time");
							YYABORT;
						}

						/* Allocate the code block */
						ALLOC_BLOCK(psCurrBlock, 1);	//1 - for OP_PAUSE
						ALLOC_DEBUG(psCurrBlock, 1);
						ip = psCurrBlock->pCode;

						/* Store the instruction */
						PUT_PKOPCODE(ip, OP_PAUSE, $3);

						/* Add the debugging information */
						if (genDebugInfo)
						{
							psCurrBlock->psDebug[0].offset = 0;
							scriptGetErrorData((SDWORD *)&line, &pDummy);
							psCurrBlock->psDebug[0].line = line;
						}

						$$ = psCurrBlock;
					}
				;

/* function return type */
return_exp:		expression
				{
					RULE("return_exp: expression");

					/* Just pass the code up the tree */
					$1->type = VAL_INT;
					$$ = $1;
				}
		|	floatexp
				{
					RULE("return_exp: floatexp");

					/* Just pass the code up the tree */
					$1->type = VAL_FLOAT;
					$$ = $1;
				}
		|	stringexp
				{
					RULE( "return_exp: stringexp");

					/* Just pass the code up the tree */
					$1->type = VAL_STRING;
					$$ = $1;
				}
		|	boolexp
				{
					RULE( "return_exp: boolexp");

					/* Just pass the code up the tree */
					$1->type = VAL_BOOL;
					$$ = $1;
				}
		|	objexp		/* example: "group", "feature", "structure.health",  "droid.numkills" */
				{
					RULE( "return_exp: objexp");

					/* Just pass the code up the tree */
					/* $1->type =  */
					$$ = $1;
				}
		|	userexp		/* templates, bodies etc */
				{
					RULE( "return_exp: userexp");

					/* Just pass the code up the tree */
					/* $1->type =  */
					$$ = $1;
				}
		;


	/* Variable assignment statements, eg:
	 *        foo = 4 + bar ;
	 */
assignment:			NUM_VAR '=' expression
						{
							RULE( "assignment: NUM_VAR '=' expression");

							codeRet = scriptCodeAssignment($1, $3, &psCurrBlock);
							CHECK_CODE_ERROR(codeRet);

							/* Return the code block */
							$$ = psCurrBlock;
						}
				|	BOOL_VAR '=' boolexp
						{
							RULE( "assignment: BOOL_VAR '=' boolexp");

							codeRet = scriptCodeAssignment($1, $3, &psCurrBlock);
							CHECK_CODE_ERROR(codeRet);

							/* Return the code block */
							$$ = psCurrBlock;
						}
				|	FLOAT_VAR '=' floatexp
						{
							RULE( "assignment: FLOAT_VAR '=' floatexp");

							codeRet = scriptCodeAssignment($1, $3, &psCurrBlock);
							CHECK_CODE_ERROR(codeRet);

							/* Return the code block */
							$$ = psCurrBlock;
						}
				|	STRING_VAR '=' stringexp
						{
							RULE("assignment: STRING_VAR '=' stringexp");

							codeRet = scriptCodeAssignment($1, $3, &psCurrBlock);
							CHECK_CODE_ERROR(codeRet);

							/* Return the code block */
							$$ = psCurrBlock;
						}
				|	OBJ_VAR '=' objexp
						{
							RULE("assignment: OBJ_VAR '=' objexp");

							if (!interpCheckEquiv($1->type, $3->type))
							{
								scr_error("User type mismatch for assignment (%d - %d) 4", $1->type, $3->type);
								YYABORT;
							}
							codeRet = scriptCodeAssignment($1, $3, &psCurrBlock);
							CHECK_CODE_ERROR(codeRet);

							/* Return the code block */
							$$ = psCurrBlock;
						}
				|	VAR '=' userexp
						{
							RULE( "assignment: VAR '=' userexp");

							if (!interpCheckEquiv($1->type, $3->type))
							{
								scr_error("User type mismatch for assignment (%d - %d) 3", $1->type, $3->type);
								YYABORT;
							}
							codeRet = scriptCodeAssignment($1, (CODE_BLOCK *)$3, &psCurrBlock);
							CHECK_CODE_ERROR(codeRet);

							/* Return the code block */
							$$ = psCurrBlock;
						}
				|	num_objvar '=' expression
						{
							RULE( "assignment: num_objvar '=' expression");

							codeRet = scriptCodeObjAssignment($1, $3, &psCurrBlock);
							CHECK_CODE_ERROR(codeRet);

							/* Return the code block */
							$$ = psCurrBlock;
						}
				|	bool_objvar '=' boolexp
						{
							RULE( "assignment: bool_objvar '=' boolexp");

							codeRet = scriptCodeObjAssignment($1, $3, &psCurrBlock);
							CHECK_CODE_ERROR(codeRet);

							/* Return the code block */
							$$ = psCurrBlock;
						}
				|	user_objvar '=' userexp
						{
							RULE( "assignment: user_objvar '=' userexp");

							if (!interpCheckEquiv($1->psObjVar->type,$3->type))
							{
								scr_error("User type mismatch for assignment (%d - %d) 2", $1->psObjVar->type, $3->type);
								YYABORT;
							}
							codeRet = scriptCodeObjAssignment($1, (CODE_BLOCK *)$3, &psCurrBlock);
							CHECK_CODE_ERROR(codeRet);

							/* Return the code block */
							$$ = psCurrBlock;
						}
				|	obj_objvar '=' objexp
						{
							RULE( "assignment: obj_objvar '=' objexp");

							if (!interpCheckEquiv($1->psObjVar->type, $3->type))
							{
								scr_error("User type mismatch for assignment (%d - %d) 1", $1->psObjVar->type, $3->type);
								YYABORT;
							}
							codeRet = scriptCodeObjAssignment($1, $3, &psCurrBlock);
							CHECK_CODE_ERROR(codeRet);

							/* Return the code block */
							$$ = psCurrBlock;
						}
				|	num_array_var '=' expression
						{
							RULE( "assignment: num_array_var '=' expression");

							codeRet = scriptCodeArrayAssignment($1, $3, &psCurrBlock);
							CHECK_CODE_ERROR(codeRet);

							/* Return the code block */
							$$ = psCurrBlock;
						}
				|	bool_array_var '=' boolexp
						{
							RULE( "assignment: bool_array_var '=' boolexp");

							codeRet = scriptCodeArrayAssignment($1, $3, &psCurrBlock);
							CHECK_CODE_ERROR(codeRet);

							/* Return the code block */
							$$ = psCurrBlock;
						}
				|	user_array_var '=' userexp
						{
							RULE( "assignment: user_array_var '=' userexp");

							if (!interpCheckEquiv($1->psArrayVar->type,$3->type))
							{
								scr_error("User type mismatch for assignment (%d - %d) 0", $1->psArrayVar->type, $3->type);
								YYABORT;
							}
							codeRet = scriptCodeArrayAssignment($1, (CODE_BLOCK *)$3, &psCurrBlock);
							CHECK_CODE_ERROR(codeRet);

							/* Return the code block */
							$$ = psCurrBlock;
						}
				|	obj_array_var '=' objexp
						{
							RULE( "assignment: obj_array_var '=' objexp");

							if (!interpCheckEquiv($1->psArrayVar->type, $3->type))
							{
								scr_error("User type mismatch for assignment");
								YYABORT;
							}
							codeRet = scriptCodeArrayAssignment($1, $3, &psCurrBlock);
							CHECK_CODE_ERROR(codeRet);

							/* Return the code block */
							$$ = psCurrBlock;
						}
				;

	/* Function calls, eg:
	 *         DisplayGlobals() ;
	 *
	 *		   If the function returns a value in a statement context
	 *		   code is generated to remove that value from the stack.
	 */
func_call:		NUM_FUNC '(' param_list ')'
					{
						RULE( "func_call: NUM_FUNC '(' param_list ')'");

						/* Generate the code for the function call */
						codeRet = scriptCodeFunction($1, $3, false, &psCurrBlock);
						CHECK_CODE_ERROR(codeRet);

						/* Return the code block */
						$$ = psCurrBlock;
					}
			|	BOOL_FUNC '(' param_list ')'
					{
						RULE( "func_call: BOOL_FUNC '(' param_list ')'");

						/* Generate the code for the function call */
						codeRet = scriptCodeFunction($1, $3, false, &psCurrBlock);
						CHECK_CODE_ERROR(codeRet);

						/* Return the code block */
						$$ = psCurrBlock;
					}
			|	USER_FUNC '(' param_list ')'
					{
						RULE( "func_call: USER_FUNC '(' param_list ')'");

						/* Generate the code for the function call */
						codeRet = scriptCodeFunction($1, $3, false, &psCurrBlock);
						CHECK_CODE_ERROR(codeRet);

						/* Return the code block */
						$$ = psCurrBlock;
					}
			|	OBJ_FUNC '(' param_list ')'
					{
						RULE( "func_call: OBJ_FUNC '(' param_list ')'");

						/* Generate the code for the function call */
						codeRet = scriptCodeFunction($1, $3, false, &psCurrBlock);
						CHECK_CODE_ERROR(codeRet);

						/* Return the code block */
						$$ = psCurrBlock;
					}
			|	FUNC '(' param_list ')'
					{
						RULE("func_call: FUNC '(' param_list ')'");

						/* Generate the code for the function call */
						codeRet = scriptCodeFunction($1, $3, false, &psCurrBlock);

						CHECK_CODE_ERROR(codeRet);

						/* Return the code block */
						$$ = psCurrBlock;
					}
			|	STRING_FUNC '(' param_list ')'
					{
						RULE( "func_call: STRING_FUNC '(' param_list ')'");

						/* Generate the code for the function call */
						codeRet = scriptCodeFunction($1, $3, false, &psCurrBlock);
						CHECK_CODE_ERROR(codeRet);

						/* Return the code block */
						$$ = psCurrBlock;
					}
			|	FLOAT_FUNC '(' param_list ')'
					{
						RULE( "func_call: FLOAT_FUNC '(' param_list ')'");

						/* Generate the code for the function call */
						codeRet = scriptCodeFunction($1, $3, false, &psCurrBlock);
						CHECK_CODE_ERROR(codeRet);

						/* Return the code block */
						$$ = psCurrBlock;
					}
			;


	/*
	 * Parse parameter lists eg:
	 *		5, foo, (bar + 4.2) / 3, foobar and barfoo
	 *
	 * These rules return PARAM_BLOCKS which contain the type of each
	 * parameter as well as the code for the parameter.
	 */

param_list:		/* NULL token */
					{
						/* create a dummy pblock containing nothing */
						//ALLOC_PBLOCK(psCurrPBlock, sizeof(UDWORD), 1);
						ALLOC_PBLOCK(psCurrPBlock, 1, 1);	//1 is enough
						psCurrPBlock->size = 0;
						psCurrPBlock->numParams = 0;

						$$ = psCurrPBlock;
					}
			|	parameter
					{
						RULE("param_list: parameter");
						$$ = $1;
					}
			|	param_list ',' parameter
					{
						RULE("param_list: param_list ',' parameter");

						ALLOC_PBLOCK(psCurrPBlock, $1->size + $3->size, $1->numParams + $3->numParams);
						ip = psCurrPBlock->pCode;

						/* Copy in the code for the parameters */
						PUT_BLOCK(ip, $1);
						PUT_BLOCK(ip, $3);

						/* Copy the parameter types */
						memcpy(psCurrPBlock->aParams, $1->aParams,
								$1->numParams * sizeof(INTERP_TYPE));
						memcpy(psCurrPBlock->aParams + $1->numParams,
								$3->aParams,
								$3->numParams * sizeof(INTERP_TYPE));

						/* Free the old pblocks */
						FREE_PBLOCK($1);
						FREE_PBLOCK($3);

						/* return the pblock */
						$$ = psCurrPBlock;
					}
			;
parameter:		expression
					{
						RULE("parameter: expression");

						/* Generate the code for the parameter                     */
						codeRet = scriptCodeParameter($1, VAL_INT, &psCurrPBlock);
						CHECK_CODE_ERROR(codeRet);

						/* Return the code block */
						$$ = psCurrPBlock;
					}
			|	boolexp
					{
						RULE("parameter: boolexp (boolexp size: %d)", $1->size);

						/* Generate the code for the parameter */
						codeRet = scriptCodeParameter($1, VAL_BOOL, &psCurrPBlock);
						CHECK_CODE_ERROR(codeRet);

						/* Return the code block */
						$$ = psCurrPBlock;
					}
			|	floatexp
					{
						RULE("parameter: floatexp");

						/* Generate the code for the parameter */
						codeRet = scriptCodeParameter($1, VAL_FLOAT, &psCurrPBlock);
						CHECK_CODE_ERROR(codeRet);

						/* Return the code block */
						$$ = psCurrPBlock;
					}
			|	stringexp
					{
						RULE("parameter: stringexp");

						/* Generate the code for the parameter */
						codeRet = scriptCodeParameter($1, VAL_STRING, &psCurrPBlock);
						CHECK_CODE_ERROR(codeRet);

						/* Return the code block */
						$$ = psCurrPBlock;
					}
			|	userexp
					{
						RULE("parameter: userexp");

						/* Generate the code for the parameter */
						codeRet = scriptCodeParameter((CODE_BLOCK *)$1, $1->type, &psCurrPBlock);
						CHECK_CODE_ERROR(codeRet);

						/* Return the code block */
						$$ = psCurrPBlock;
					}
			|	objexp
					{
						RULE( "parameter: objexp");

						/* Generate the code for the parameter */
						codeRet = scriptCodeParameter($1, $1->type, &psCurrPBlock);
						CHECK_CODE_ERROR(codeRet);

						/* Return the code block */
						$$ = psCurrPBlock;
					}
			|	var_ref
					{
						/* just pass the variable reference up the tree */
						$$ = $1;
					}
			;

var_ref:		REF NUM_VAR
					{
						codeRet = scriptCodeVarRef($2, &psCurrPBlock);
						CHECK_CODE_ERROR(codeRet);

						/* Return the code block */
						$$ = psCurrPBlock;
					}
			|	REF FLOAT_VAR
					{
						codeRet = scriptCodeVarRef($2, &psCurrPBlock);
						CHECK_CODE_ERROR(codeRet);

						/* Return the code block */
						$$ = psCurrPBlock;
					}
			|	REF BOOL_VAR
					{
						codeRet = scriptCodeVarRef($2, &psCurrPBlock);
						CHECK_CODE_ERROR(codeRet);

						/* Return the code block */
						$$ = psCurrPBlock;
					}
			|	REF STRING_VAR
					{
						codeRet = scriptCodeVarRef($2, &psCurrPBlock);
						CHECK_CODE_ERROR(codeRet);

						/* Return the code block */
						$$ = psCurrPBlock;
					}
			|	REF VAR
					{
						codeRet = scriptCodeVarRef($2, &psCurrPBlock);
						CHECK_CODE_ERROR(codeRet);

						/* Return the code block */
						$$ = psCurrPBlock;
					}
			|	REF OBJ_VAR
					{
						codeRet = scriptCodeVarRef($2, &psCurrPBlock);
						CHECK_CODE_ERROR(codeRet);

						/* Return the code block */
						$$ = psCurrPBlock;
					}
			;

	/*
	 * Conditional statements, can be :
	 *
	 */

conditional:		cond_clause_list
					{
						RULE( "conditional: cond_clause_list");

						codeRet = scriptCodeConditional($1, &psCurrBlock);
						CHECK_CODE_ERROR(codeRet);

						$$ = psCurrBlock;
					}
				|	cond_clause_list ELSE terminal_cond
					{
						RULE( "conditional: cond_clause_list ELSE terminal_cond");

						ALLOC_CONDBLOCK(psCondBlock, $1->numOffsets + $3->numOffsets, $1->size + $3->size);
						ALLOC_DEBUG(psCondBlock, $1->debugEntries + $3->debugEntries);
						ip = psCondBlock->pCode;

						/* Store the two blocks of code */
						PUT_BLOCK(ip, $1);
						PUT_BLOCK(ip, $3);

						/* Copy over the offset information       */
						/* (There isn't any in the terminal_cond) */
						memcpy(psCondBlock->aOffsets, $1->aOffsets,
							   $1->numOffsets * sizeof(SDWORD));
						psCondBlock->numOffsets = $1->numOffsets;

						/* Put in the debugging information */
						PUT_DEBUG(psCondBlock, $1);
						APPEND_DEBUG(psCondBlock, $1->size, $3);

						/* Free the code blocks */
						FREE_DEBUG($1);
						FREE_DEBUG($3);
						FREE_CONDBLOCK($1);
						FREE_CONDBLOCK($3);

						/* Do the final processing of the conditional */
						codeRet = scriptCodeConditional(psCondBlock, &psCurrBlock);
						CHECK_CODE_ERROR(codeRet);

						$$ = psCurrBlock;
					}
				;

cond_clause_list:	cond_clause
					{
						RULE( "cond_clause_list:	cond_clause");

						$$ = $1;
					}
				|	cond_clause_list ELSE cond_clause
					{
						RULE( "cond_clause_list:	cond_clause_list ELSE cond_clause");

						ALLOC_CONDBLOCK(psCondBlock,
										$1->numOffsets + $3->numOffsets,
										$1->size + $3->size);
						ALLOC_DEBUG(psCondBlock, $1->debugEntries + $3->debugEntries);
						ip = psCondBlock->pCode;

						/* Store the two blocks of code */
						PUT_BLOCK(ip, $1);
						PUT_BLOCK(ip, $3);

						/* Copy over the offset information */
						memcpy(psCondBlock->aOffsets, $1->aOffsets,
							   $1->numOffsets * sizeof(SDWORD));
						psCondBlock->aOffsets[$1->numOffsets] =
							$3->aOffsets[0] + $1->size;
						psCondBlock->numOffsets = $1->numOffsets + 1;

						/* Put in the debugging information */
						PUT_DEBUG(psCondBlock, $1);
						APPEND_DEBUG(psCondBlock, $1->size, $3);

						/* Free the code blocks */
						FREE_DEBUG($1);
						FREE_DEBUG($3);
						FREE_CONDBLOCK($1);
						FREE_CONDBLOCK($3);

						$$ = psCondBlock;
					}
				;


terminal_cond:		'{' statement_list '}'
					{
						RULE( "terminal_cond: '{' statement_list '}'");

						/* Allocate the block */
						ALLOC_CONDBLOCK(psCondBlock, 1, $2->size);
						ALLOC_DEBUG(psCondBlock, $2->debugEntries);
						ip = psCondBlock->pCode;

						/* Put in the debugging information */
						PUT_DEBUG(psCondBlock, $2);

						/* Store the statements */
						PUT_BLOCK(ip, $2);
						FREE_DEBUG($2);
						FREE_BLOCK($2);

						$$ = psCondBlock;
					}
				;

cond_clause:		IF '(' boolexp ')'
					{
						char *pDummy;

						RULE( "cond_clause: IF '(' boolexp ')' '{' statement_list '}'");

						/* Get the line number for the end of the boolean expression */
						/* and store it in debugLine.                                 */
						scriptGetErrorData((SDWORD *)&debugLine, &pDummy);
					}
						'{' statement_list '}'
					{
						/* Allocate the block */
						ALLOC_CONDBLOCK(psCondBlock, 1,	//1 offset
										$3->size + $7->size +
										1 + 1);		//size + size + OP_JUMPFALSE + OP_JUMP

						ALLOC_DEBUG(psCondBlock, $7->debugEntries + 1);
						ip = psCondBlock->pCode;

						/* Store the boolean expression code */
						PUT_BLOCK(ip, $3);
						FREE_BLOCK($3);

						/* Put in the jump to the end of the block if the */
						/* condition is false */
						PUT_PKOPCODE(ip, OP_JUMPFALSE, $7->size + 2);

						/* Put in the debugging information */
						if (genDebugInfo)
						{
							psCondBlock->debugEntries = 1;
							psCondBlock->psDebug->line = debugLine;
							psCondBlock->psDebug->offset = 0;
							APPEND_DEBUG(psCondBlock, ip - psCondBlock->pCode, $7);
						}

						/* Store the statements */
						PUT_BLOCK(ip, $7);
						FREE_DEBUG($7);
						FREE_BLOCK($7);

						/* Store the location that has to be filled in   */
						//TODO: don't want to store pointers as ints
						psCondBlock->aOffsets[0] = (UDWORD)(ip - psCondBlock->pCode);

						/* Put in a jump to skip the rest of the conditional */
						/* The correct offset will be set once the whole   */
						/* conditional has been parsed                     */
						/* The jump should be to the instruction after the */
						/* entire conditonal block                         */
						PUT_PKOPCODE(ip, OP_JUMP, 0);

						$$ = psCondBlock;
					}
				/* 'Monoblock' */
				|		IF '(' boolexp ')'
					{
						char *pDummy;

						RULE( "cond_clause: IF '(' boolexp ')' statement");

						/* Get the line number for the end of the boolean expression */
						/* and store it in debugLine.                                 */
						scriptGetErrorData((SDWORD *)&debugLine, &pDummy);
					}
							statement
					{
						/* Allocate the block */
						ALLOC_CONDBLOCK(psCondBlock, 1,
										$3->size + $6->size +
										1 + 1);		//size + size + opcode + opcode

						ALLOC_DEBUG(psCondBlock, $6->debugEntries + 1);
						ip = psCondBlock->pCode;

						/* Store the boolean expression code */
						PUT_BLOCK(ip, $3);
						FREE_BLOCK($3);


						/* Put in the jump to the end of the block if the */
						/* condition is false */
						PUT_PKOPCODE(ip, OP_JUMPFALSE, $6->size + 2);

						/* Put in the debugging information */
						if (genDebugInfo)
						{
							psCondBlock->debugEntries = 1;
							psCondBlock->psDebug->line = debugLine;
							psCondBlock->psDebug->offset = 0;
							APPEND_DEBUG(psCondBlock, ip - psCondBlock->pCode, $6);
						}

						/* Store the statements */
						PUT_BLOCK(ip, $6);
						FREE_DEBUG($6);
						FREE_BLOCK($6);

						/* Store the location that has to be filled in   */
						psCondBlock->aOffsets[0] = (UDWORD)(ip - psCondBlock->pCode);

						/* Put in a jump to skip the rest of the conditional */
						/* The correct offset will be set once the whole   */
						/* conditional has been parsed                     */
						/* The jump should be to the instruction after the */
						/* entire conditonal block                         */
						PUT_PKOPCODE(ip, OP_JUMP, 0);

						$$ = psCondBlock;
					}
				;


	/*
	 * while loops, e.g.
	 *
	 * while (i < 5)
	 * {
	 *    ....
	 *    i = i + 1;
	 * }
	 */
loop:			WHILE '(' boolexp ')'
				{
					char *pDummy;

					/* Get the line number for the end of the boolean expression */
					/* and store it in debugLine.                                 */
					scriptGetErrorData((SDWORD *)&debugLine, &pDummy);
				}
								 '{' statement_list '}'
				{
					RULE("loop: WHILE '(' boolexp ')'");

					//ALLOC_BLOCK(psCurrBlock, $3->size + $7->size + sizeof(OPCODE) * 2);
					ALLOC_BLOCK(psCurrBlock, $3->size + $7->size + 1 + 1);	//size + size + opcode + opcode

					ALLOC_DEBUG(psCurrBlock, $7->debugEntries + 1);
					ip = psCurrBlock->pCode;

					/* Copy in the loop expression */
					PUT_BLOCK(ip, $3);
					FREE_BLOCK($3);

					/* Now a conditional jump out of the loop if the */
					/* expression is false.                          */
					PUT_PKOPCODE(ip, OP_JUMPFALSE, $7->size + 2);

					/* Now put in the debugging information */
					if (genDebugInfo)
					{
						psCurrBlock->debugEntries = 1;
						psCurrBlock->psDebug->line = debugLine;
						psCurrBlock->psDebug->offset = 0;
						APPEND_DEBUG(psCurrBlock, ip - psCurrBlock->pCode, $7);
					}

					/* Copy in the body of the loop */
					PUT_BLOCK(ip, $7);
					FREE_DEBUG($7);
					FREE_BLOCK($7);

					/* Put in a jump back to the start of the loop expression */
					PUT_PKOPCODE(ip, OP_JUMP, (SWORD)( -(SWORD)(psCurrBlock->size) + 1));

					$$ = psCurrBlock;
				}
		;

/* Increment/Decrement expressions */
inc_dec_exp:	NUM_VAR _INC
				{
					RULE("expression: NUM_VAR++");

					scriptCodeIncDec($1, &psCurrBlock, OP_INC);

					/* Return the code block */
					$$ = psCurrBlock;
				}
			|	NUM_VAR _DEC
				{
					RULE("expression: NUM_VAR--");

					scriptCodeIncDec($1, &psCurrBlock, OP_DEC);

					/* Return the code block */
					$$ = psCurrBlock;
				}
			;

	/**************************************************************************************
	 *
	 * Mathematical expressions
	 */

expression:		expression '+' expression
				{
					codeRet = scriptCodeBinaryOperator($1, $3, OP_ADD, &psCurrBlock);
					CHECK_CODE_ERROR(codeRet);

					/* Return the code block */
					$$ = psCurrBlock;
				}
			|	expression '-' expression
				{
					codeRet = scriptCodeBinaryOperator($1, $3, OP_SUB, &psCurrBlock);
					CHECK_CODE_ERROR(codeRet);

					/* Return the code block */
					$$ = psCurrBlock;
				}
			|	expression '*' expression
				{
					codeRet = scriptCodeBinaryOperator($1, $3, OP_MUL, &psCurrBlock);
					CHECK_CODE_ERROR(codeRet);

					/* Return the code block */
					$$ = psCurrBlock;
				}
			|	expression '/' expression
				{
					codeRet = scriptCodeBinaryOperator($1, $3, OP_DIV, &psCurrBlock);
					CHECK_CODE_ERROR(codeRet);

					/* Return the code block */
					$$ = psCurrBlock;
				}

			|	'-' expression %prec UMINUS
				{
					//ALLOC_BLOCK(psCurrBlock, $2->size + sizeof(OPCODE));
					ALLOC_BLOCK(psCurrBlock, $2->size + 1);	//size + unary minus opcode

					ip = psCurrBlock->pCode;

					/* Copy the already generated bits of code into the code block */
					PUT_BLOCK(ip, $2);

					/* Now put a negation operator into the code */
					PUT_PKOPCODE(ip, OP_UNARYOP, OP_NEG);

					/* Free the two code blocks that have been copied */
					FREE_BLOCK($2);

					/* Return the code block */
					$$ = psCurrBlock;
				}
			|	'(' expression ')'
				{
					/* Just pass the code up the tree */
					$$ = $2;
				}
			|	TO_INT_CAST floatexp
				{
					RULE("expression: (int) floatexp");

					/* perform cast */
					$2->type = VAL_INT;

					//ALLOC_BLOCK(psCurrBlock, $4->size + sizeof(OPCODE));
					ALLOC_BLOCK(psCurrBlock, $2->size + 1);		//size + opcode
					ip = psCurrBlock->pCode;

					PUT_BLOCK(ip, $2);
					PUT_OPCODE(ip, OP_TO_INT);

					FREE_BLOCK($2);		// free floatexp

					$$ = psCurrBlock;
				}
			|	NUM_FUNC '(' param_list ')'
				{

					RULE( "expression: NUM_FUNC '(' param_list ')'");

					/* Generate the code for the function call */
					codeRet = scriptCodeFunction($1, $3, true, &psCurrBlock);
					CHECK_CODE_ERROR(codeRet);

					/* Return the code block */
					$$ = psCurrBlock;
				}

			|	NUM_FUNC_CUST '(' param_list ')'
				{
					UDWORD paramNumber;

					RULE( "expression: NUM_FUNC_CUST '(' param_list ')'");

					/* if($4->numParams != $3->numParams) */
					if($3->numParams != $1->numParams)
					{
						debug(LOG_ERROR, "Wrong number of arguments for function call: '%s'. Expected %d parameters instead of  %d.", $1->pIdent, $1->numParams, $3->numParams);
						scr_error("Wrong number of arguments in function call");
						return CE_PARSE;
					}

					if(!$1->bFunction)
					{
						debug(LOG_ERROR, "'%s' is not a function", $1->pIdent);
						scr_error("Can't call an event");
						return CE_PARSE;
					}

					/* make sure function has a return type */
					if($1->retType != VAL_INT)
					{
						debug(LOG_ERROR, "'%s' does not return an integer value", $1->pIdent);
						scr_error("assignment type conflict");
						return CE_PARSE;
					}

					/* check if right parameters were passed */
					paramNumber = checkFuncParamTypes($1, $3);
					if(paramNumber > 0)
					{
						debug(LOG_ERROR, "Parameter mismatch in function call: '%s'. Mismatch in parameter  %d.", $1->pIdent, paramNumber);
						YYABORT;
					}

					/* Allocate the code block */
					ALLOC_BLOCK(psCurrBlock, $3->size + 1 + 1);	//Params + Opcode + event index

					ip = psCurrBlock->pCode;

					if($3->numParams > 0)	/* if any parameters declared */
					{
						/* Copy in the code for the parameters */
						PUT_BLOCK(ip, $3);
					}

					FREE_PBLOCK($3);

					/* Store the instruction */
					PUT_OPCODE(ip, OP_FUNC);
					PUT_EVENT(ip,$1->index);			//Put event index

					$$ = psCurrBlock;
				}
			|	NUM_VAR
				{
					RULE("expression: NUM_VAR");

					codeRet = scriptCodeVarGet($1, &psCurrBlock);
					CHECK_CODE_ERROR(codeRet);

					/* Return the code block */
					$$ = psCurrBlock;
				}
			|	NUM_CONSTANT
				{
					RULE("expression: NUM_CONSTANT");

					codeRet = scriptCodeConstant($1, &psCurrBlock);
					CHECK_CODE_ERROR(codeRet);

					/* Return the code block */
					$$ = psCurrBlock;
				}
			|	num_objvar
				{
					RULE( "expression: num_objvar");
					RULE( "type=%d", $1->psObjVar->type);

					codeRet = scriptCodeObjGet($1, &psCurrBlock);
					CHECK_CODE_ERROR(codeRet);

					/* Return the code block */
					$$ = psCurrBlock;
				}
			|	num_array_var
				{
					codeRet = scriptCodeArrayGet($1, &psCurrBlock);
					CHECK_CODE_ERROR(codeRet);

					/* Return the code block */
					$$ = psCurrBlock;
				}
			|	INTEGER
				{
					RULE("expression: INTEGER");

					//ALLOC_BLOCK(psCurrBlock, sizeof(OPCODE) + sizeof(UDWORD));
					ALLOC_BLOCK(psCurrBlock, 1 + 1);	//opcode + integer value

					ip = psCurrBlock->pCode;

					/* Code to store the value on the stack */
					PUT_PKOPCODE(ip, OP_PUSH, VAL_INT);
					PUT_DATA_INT(ip, $1);

					/* Return the code block */
					$$ = psCurrBlock;
				}
			;

floatexp:		floatexp '+' floatexp
				{
					codeRet = scriptCodeBinaryOperator($1, $3, OP_ADD, &psCurrBlock);
					CHECK_CODE_ERROR(codeRet);

					/* Return the code block */
					$$ = psCurrBlock;
				}
			|	floatexp '-' floatexp
				{
					codeRet = scriptCodeBinaryOperator($1, $3, OP_SUB, &psCurrBlock);
					CHECK_CODE_ERROR(codeRet);

					/* Return the code block */
					$$ = psCurrBlock;
				}
			|	floatexp '*' floatexp
				{
					codeRet = scriptCodeBinaryOperator($1, $3, OP_MUL, &psCurrBlock);
					CHECK_CODE_ERROR(codeRet);

					/* Return the code block */
					$$ = psCurrBlock;
				}
			|	floatexp '/' floatexp
				{
					codeRet = scriptCodeBinaryOperator($1, $3, OP_DIV, &psCurrBlock);
					CHECK_CODE_ERROR(codeRet);

					/* Return the code block */
					$$ = psCurrBlock;
				}
			|	TO_FLOAT_CAST expression
				{
					RULE("floatexp: (float) expression");

					/* perform cast */
					 $2->type = VAL_FLOAT;

					ALLOC_BLOCK(psCurrBlock, $2->size + 1);	//size + opcode
					ip = psCurrBlock->pCode;

					PUT_BLOCK(ip, $2);
					PUT_OPCODE(ip, OP_TO_FLOAT);
					
					FREE_BLOCK($2);		// free 'expression'

					$$ = psCurrBlock;
				}
			|	'-' floatexp %prec UMINUS
				{
					ALLOC_BLOCK(psCurrBlock, $2->size + 1);	//size + opcode

					ip = psCurrBlock->pCode;

					/* Copy the already generated bits of code into the code block */
					PUT_BLOCK(ip, $2);

					/* Now put a negation operator into the code */
					PUT_PKOPCODE(ip, OP_UNARYOP, OP_NEG);

					/* Free the code block that have been copied */
					FREE_BLOCK($2);

					/* Return the code block */
					$$ = psCurrBlock;
				}
			|	'(' floatexp ')'
				{
					/* Just pass the code up the tree */
					$$ = $2;
				}
			|	FLOAT_FUNC '(' param_list ')'
				{
					RULE("floatexp: FLOAT_FUNC '(' param_list ')'");

					/* Generate the code for the function call */
					codeRet = scriptCodeFunction($1, $3, true, &psCurrBlock);
					CHECK_CODE_ERROR(codeRet);

					/* Return the code block */
					$$ = psCurrBlock;
				}
			|	FLOAT_FUNC_CUST '(' param_list ')'
				{
						UDWORD line,paramNumber;
						char *pDummy;

						RULE("floatexp: FLOAT_FUNC_CUST '(' param_list ')'");

						if($3->numParams != $1->numParams)
						{
							debug(LOG_ERROR, "Wrong number of arguments for function call: '%s'. Expected %d parameters instead of  %d.", $1->pIdent, $1->numParams, $3->numParams);
							scr_error("Wrong number of arguments in function call");
							return CE_PARSE;
						}

						if(!$1->bFunction)
						{
							debug(LOG_ERROR, "'%s' is not a function", $1->pIdent);
							scr_error("Can't call an event");
							return CE_PARSE;
						}

						/* make sure function has a return type */
						if($1->retType != VAL_FLOAT)
						{
							debug(LOG_ERROR, "'%s' does not return a float value", $1->pIdent);
							scr_error("assignment type conflict");
							return CE_PARSE;
						}

						/* check if right parameters were passed */
						paramNumber = checkFuncParamTypes($1, $3);
						if(paramNumber > 0)
						{
							debug(LOG_ERROR, "Parameter mismatch in function call: '%s'. Mismatch in parameter  %d.", $1->pIdent, paramNumber);
							YYABORT;
						}

						/* Allocate the code block */
						ALLOC_BLOCK(psCurrBlock, $3->size + 1 + 1);	//Params + Opcode + event index

						ALLOC_DEBUG(psCurrBlock, 1);
						ip = psCurrBlock->pCode;

						if($3->numParams > 0)	/* if any parameters declared */
						{
							/* Copy in the code for the parameters */
							PUT_BLOCK(ip, $3);
						}

						FREE_PBLOCK($3);

						/* Store the instruction */
						PUT_OPCODE(ip, OP_FUNC);
						PUT_EVENT(ip,$1->index);		//Put event/function index

						/* Add the debugging information */
						if (genDebugInfo)
						{
							psCurrBlock->psDebug[0].offset = 0;
							scriptGetErrorData((SDWORD *)&line, &pDummy);
							psCurrBlock->psDebug[0].line = line;
						}

						$$ = psCurrBlock;
				}
			|	FLOAT_VAR
				{
					RULE( "floatexp: FLOAT_VAR");

					codeRet = scriptCodeVarGet($1, &psCurrBlock);
					CHECK_CODE_ERROR(codeRet);

					/* Return the code block */
					$$ = psCurrBlock;
				}
			|	FLOAT_T
				{
					RULE( "floatexp: FLOAT_T");

					//ALLOC_BLOCK(psCurrBlock, sizeof(OPCODE) + sizeof(float));
					ALLOC_BLOCK(psCurrBlock, 1 + 1);		//opcode + float

					ip = psCurrBlock->pCode;

					/* Code to store the value on the stack */
					PUT_PKOPCODE(ip, OP_PUSH, VAL_FLOAT);
					PUT_DATA_FLOAT(ip, $1);

					/* Return the code block */
					$$ = psCurrBlock;
				}
			;


	/***************************************************************************************
	 *
	 * String expressions
	 */
stringexp:
			stringexp '&' stringexp
				{
					RULE("stringexp: stringexp '&' stringexp");

					codeRet = scriptCodeBinaryOperator($1, $3, OP_CONC, &psCurrBlock);
					CHECK_CODE_ERROR(codeRet);

					/* Return the code block */
					$$ = psCurrBlock;

					//debug(LOG_SCRIPT, "END stringexp: stringexp '&' stringexp");
				}
		| 	stringexp '&' expression
				{
					RULE( "stringexp: stringexp '&' expression");

					codeRet = scriptCodeBinaryOperator($1, $3, OP_CONC, &psCurrBlock);
					CHECK_CODE_ERROR(codeRet);

					/* Return the code block */
					$$ = psCurrBlock;
				}
		| 	expression '&' stringexp
				{
					RULE( "stringexp: expression '&' stringexp");

					codeRet = scriptCodeBinaryOperator($1, $3, OP_CONC, &psCurrBlock);
					CHECK_CODE_ERROR(codeRet);

					/* Return the code block */
					$$ = psCurrBlock;
				}
		| 	stringexp '&' boolexp
				{
					RULE( "stringexp: stringexp '&' boolexp");

					codeRet = scriptCodeBinaryOperator($1, $3, OP_CONC, &psCurrBlock);
					CHECK_CODE_ERROR(codeRet);

					/* Return the code block */
					$$ = psCurrBlock;
				}
		| 	boolexp '&' stringexp
				{
					RULE( "stringexp: boolexp '&' stringexp");

					codeRet = scriptCodeBinaryOperator($1, $3, OP_CONC, &psCurrBlock);
					CHECK_CODE_ERROR(codeRet);

					/* Return the code block */
					$$ = psCurrBlock;
				}
		| 	stringexp '&' floatexp
				{
					RULE( "stringexp: stringexp '&' floatexp");

					codeRet = scriptCodeBinaryOperator($1, $3, OP_CONC, &psCurrBlock);
					CHECK_CODE_ERROR(codeRet);

					/* Return the code block */
					$$ = psCurrBlock;
				}
		| 	floatexp '&' stringexp
				{
					RULE( "stringexp: floatexp '&' stringexp");

					codeRet = scriptCodeBinaryOperator($1, $3, OP_CONC, &psCurrBlock);
					CHECK_CODE_ERROR(codeRet);

					/* Return the code block */
					$$ = psCurrBlock;
				}
			|	'(' stringexp ')'
				{
					/* Just pass the code up the tree */
					$$ = $2;
				}

			|	STRING_FUNC '(' param_list ')'
				{
					RULE("stringexp: STRING_FUNC '(' param_list ')'");

					/* Generate the code for the function call */
					codeRet = scriptCodeFunction($1, $3, true, &psCurrBlock);
					CHECK_CODE_ERROR(codeRet);

					/* Return the code block */
					$$ = psCurrBlock;
				}
			|	STRING_FUNC_CUST '(' param_list ')'
				{
						RULE("stringexp: STRING_FUNC_CUST '(' param_list ')'");

						if($3->numParams != $1->numParams)
						{
							debug(LOG_ERROR, "Wrong number of arguments for function call: '%s'. Expected %d parameters instead of  %d.", $1->pIdent, $1->numParams, $3->numParams);
							scr_error("Wrong number of arguments in function call");
							return CE_PARSE;
						}

						if(!$1->bFunction)
						{
							debug(LOG_ERROR, "'%s' is not a function", $1->pIdent);
							scr_error("Can't call an event");
							return CE_PARSE;
						}

						/* make sure function has a return type */
						if($1->retType != VAL_STRING)
						{
							debug(LOG_ERROR, "'%s' does not return a string value", $1->pIdent);
							scr_error("assignment type conflict");
							return CE_PARSE;
						}

						/* Allocate the code block */
						ALLOC_BLOCK(psCurrBlock, $3->size + 1 + 1);	//Params + Opcode + event index

						ip = psCurrBlock->pCode;

						if($3->numParams > 0)	/* if any parameters declared */
						{
							/* Copy in the code for the parameters */
							PUT_BLOCK(ip, $3);
						}

						FREE_PBLOCK($3);

						/* Store the instruction */
						PUT_OPCODE(ip, OP_FUNC);
						PUT_EVENT(ip,$1->index);			//Put event index

						$$ = psCurrBlock;
				}

		|	STRING_VAR
				{
					RULE("stringexpr: STRING_VAR");

					codeRet = scriptCodeVarGet($1, &psCurrBlock);
					CHECK_CODE_ERROR(codeRet);

					/* Return the code block */
					$$ = psCurrBlock;
				}
		|	QTEXT
				{
					RULE("QTEXT: '%s'", yyvsp[0].sval);

					//ALLOC_BLOCK(psCurrBlock, sizeof(OPCODE) + sizeof(UDWORD));
					ALLOC_BLOCK(psCurrBlock, 1 + 1);	//opcode + string pointer

					ip = psCurrBlock->pCode;

					/* Code to store the value on the stack */
					PUT_PKOPCODE(ip, OP_PUSH, VAL_STRING);
					PUT_DATA_STRING(ip, STRSTACK[CURSTACKSTR]);

					/* Return the code block */
					$$ = psCurrBlock;

					/* Manage string stack */
					sstrcpy(STRSTACK[CURSTACKSTR], yyvsp[0].sval);

					CURSTACKSTR = CURSTACKSTR + 1;		/* Increment 'pointer' to the top of the string stack */

					if(CURSTACKSTR >= MAXSTACKLEN)
					{
						scr_error("Can't store more than %d strings", MAXSTACKLEN);
					}

					//debug(LOG_SCRIPT, "END QTEXT found");
				}
		|		expression
				{
					RULE( "stringexp: expression");

					/* Just pass the code up the tree */
					$$ = $1;
				}
			;


	/***************************************************************************************
	 *
	 * Boolean expressions
	 */

boolexp:		boolexp _AND boolexp
				{
					codeRet = scriptCodeBinaryOperator($1, $3, OP_AND, &psCurrBlock);
					CHECK_CODE_ERROR(codeRet);

					/* Return the code block */
					$$ = psCurrBlock;
				}
			|	boolexp _OR boolexp
				{
					codeRet = scriptCodeBinaryOperator($1, $3, OP_OR, &psCurrBlock);
					CHECK_CODE_ERROR(codeRet);

					/* Return the code block */
					$$ = psCurrBlock;
				}
			|	boolexp BOOLEQUAL boolexp
				{
					codeRet = scriptCodeBinaryOperator($1, $3, OP_EQUAL, &psCurrBlock);
					CHECK_CODE_ERROR(codeRet);

					/* Return the code block */
					$$ = psCurrBlock;
				}
			|	boolexp NOTEQUAL boolexp
				{
					codeRet = scriptCodeBinaryOperator($1, $3, OP_NOTEQUAL, &psCurrBlock);
					CHECK_CODE_ERROR(codeRet);

					/* Return the code block */
					$$ = psCurrBlock;
				}
			|	_NOT boolexp
				{
					//ALLOC_BLOCK(psCurrBlock, $2->size + sizeof(OPCODE));
					ALLOC_BLOCK(psCurrBlock, $2->size + 1);	//size + opcode

					ip = psCurrBlock->pCode;

					/* Copy the already generated bits of code into the code block */
					PUT_BLOCK(ip, $2);

					/* Now put a negation operator into the code */
					PUT_PKOPCODE(ip, OP_UNARYOP, OP_NOT);

					/* Free the two code blocks that have been copied */
					FREE_BLOCK($2);

					/* Return the code block */
					$$ = psCurrBlock;
				}
			|	'(' boolexp ')'
				{
					/* Just pass the code up the tree */
					$$ = $2;
				}
			|	BOOL_FUNC '(' param_list ')'
				{
					RULE("boolexp: BOOL_FUNC '(' param_list ')'");

					/* Generate the code for the function call */
					codeRet = scriptCodeFunction($1, $3, true, &psCurrBlock);
					CHECK_CODE_ERROR(codeRet);

					/* Return the code block */
					$$ = psCurrBlock;
				}
			|	BOOL_FUNC_CUST '(' param_list ')'
				{
						UDWORD paramNumber;

						RULE("boolexp: BOOL_FUNC_CUST '(' param_list ')'");

						if($3->numParams != $1->numParams)
						{
							debug(LOG_ERROR, "Wrong number of arguments for function call: '%s'. Expected %d parameters instead of  %d.", $1->pIdent, $1->numParams, $3->numParams);
							scr_error("Wrong number of arguments in function call");
							return CE_PARSE;
						}

						if(!$1->bFunction)
						{
							debug(LOG_ERROR, "'%s' is not a function", $1->pIdent);
							scr_error("Can't call an event");
							return CE_PARSE;
						}

						/* make sure function has a return type */
						if($1->retType != VAL_BOOL)
						{
							debug(LOG_ERROR, "'%s' does not return a boolean value", $1->pIdent);
							scr_error("assignment type conflict");
							return CE_PARSE;
						}

						/* check if right parameters were passed */
						paramNumber = checkFuncParamTypes($1, $3);
						if(paramNumber > 0)
						{
							debug(LOG_ERROR, "Parameter mismatch in function call: '%s'. Mismatch in parameter  %d.", $1->pIdent, paramNumber);
							YYABORT;
						}

						/* Allocate the code block */
						ALLOC_BLOCK(psCurrBlock, $3->size + 1 + 1);	//Params + Opcode + event index

						ip = psCurrBlock->pCode;

						if($3->numParams > 0)	/* if any parameters declared */
						{
							/* Copy in the code for the parameters */
							PUT_BLOCK(ip, $3);
						}

						FREE_PBLOCK($3);

						/* Store the instruction */
						PUT_OPCODE(ip, OP_FUNC);
						PUT_EVENT(ip,$1->index);		//Put event/function index

						$$ = psCurrBlock;
				}
			|	BOOL_VAR
				{
					RULE("boolexp: BOOL_VAR");

					codeRet = scriptCodeVarGet($1, &psCurrBlock);
					CHECK_CODE_ERROR(codeRet);

					/* Return the code block */
					$$ = psCurrBlock;
				}
			|	BOOL_CONSTANT
				{
					RULE("boolexp: BOOL_CONSTANT");

					codeRet = scriptCodeConstant($1, &psCurrBlock);
					CHECK_CODE_ERROR(codeRet);

					/* Return the code block */
					$$ = psCurrBlock;
				}
			|	bool_objvar
				{
					codeRet = scriptCodeObjGet($1, &psCurrBlock);
					CHECK_CODE_ERROR(codeRet);

					/* Return the code block */
					$$ = psCurrBlock;
				}
			|	bool_array_var
				{
					codeRet = scriptCodeArrayGet($1, &psCurrBlock);
					CHECK_CODE_ERROR(codeRet);

					/* Return the code block */
					$$ = psCurrBlock;
				}
			|	BOOLEAN_T
				{
					RULE("boolexp: BOOLEAN_T");

					//ALLOC_BLOCK(psCurrBlock, sizeof(OPCODE) + sizeof(UDWORD));
					ALLOC_BLOCK(psCurrBlock, 1 + 1);	//opcode + value
					ip = psCurrBlock->pCode;

					/* Code to store the value on the stack */
					PUT_PKOPCODE(ip, OP_PUSH, VAL_BOOL);
					PUT_DATA_BOOL(ip, $1);

					/* Return the code block */
					$$ = psCurrBlock;
				}
			|	expression BOOLEQUAL expression
				{
					codeRet = scriptCodeBinaryOperator($1, $3, OP_EQUAL, &psCurrBlock);
					CHECK_CODE_ERROR(codeRet);

					/* Return the code block */
					$$ = psCurrBlock;
				}
			|	floatexp BOOLEQUAL floatexp
				{
					codeRet = scriptCodeBinaryOperator($1, $3, OP_EQUAL, &psCurrBlock);
					CHECK_CODE_ERROR(codeRet);

					/* Return the code block */
					$$ = psCurrBlock;
				}
			|	stringexp BOOLEQUAL stringexp
				{
					codeRet = scriptCodeBinaryOperator($1, $3, OP_EQUAL, &psCurrBlock);
					CHECK_CODE_ERROR(codeRet);

					/* Return the code block */
					$$ = psCurrBlock;
				}
			|	userexp BOOLEQUAL userexp
				{
					if (!interpCheckEquiv($1->type,$3->type))
					{
						scr_error("Type mismatch for equality");
						YYABORT;
					}
					codeRet = scriptCodeBinaryOperator($1, $3, OP_EQUAL, &psCurrBlock);
					CHECK_CODE_ERROR(codeRet);

					/* Return the code block */
					$$ = psCurrBlock;
				}
			|	objexp BOOLEQUAL objexp
				{
					if (!interpCheckEquiv($1->type,$3->type))
					{
						scr_error("Type mismatch for equality");
						YYABORT;
					}
					codeRet = scriptCodeBinaryOperator($1, $3, OP_EQUAL, &psCurrBlock);
					CHECK_CODE_ERROR(codeRet);

					/* Return the code block */
					$$ = psCurrBlock;
				}
			|	expression NOTEQUAL expression
				{
					codeRet = scriptCodeBinaryOperator($1, $3, OP_NOTEQUAL, &psCurrBlock);
					CHECK_CODE_ERROR(codeRet);

					/* Return the code block */
					$$ = psCurrBlock;
				}
			|	floatexp NOTEQUAL floatexp
				{
					codeRet = scriptCodeBinaryOperator($1, $3, OP_NOTEQUAL, &psCurrBlock);
					CHECK_CODE_ERROR(codeRet);

					/* Return the code block */
					$$ = psCurrBlock;
				}
			|	stringexp NOTEQUAL stringexp
				{
					codeRet = scriptCodeBinaryOperator($1, $3, OP_NOTEQUAL, &psCurrBlock);
					CHECK_CODE_ERROR(codeRet);

					/* Return the code block */
					$$ = psCurrBlock;
				}
			|	userexp NOTEQUAL userexp
				{
					if (!interpCheckEquiv($1->type,$3->type))
					{
						scr_error("Type mismatch for inequality");
						YYABORT;
					}
					codeRet = scriptCodeBinaryOperator($1, $3, OP_NOTEQUAL, &psCurrBlock);
					CHECK_CODE_ERROR(codeRet);

					/* Return the code block */
					$$ = psCurrBlock;
				}
			|	objexp NOTEQUAL objexp
				{
					if (!interpCheckEquiv($1->type,$3->type))
					{
						scr_error("Type mismatch for inequality");
						YYABORT;
					}
					codeRet = scriptCodeBinaryOperator($1, $3, OP_NOTEQUAL, &psCurrBlock);
					CHECK_CODE_ERROR(codeRet);

					/* Return the code block */
					$$ = psCurrBlock;
				}
			|	expression LESSEQUAL expression
				{
					codeRet = scriptCodeBinaryOperator($1, $3, OP_LESSEQUAL, &psCurrBlock);
					CHECK_CODE_ERROR(codeRet);

					/* Return the code block */
					$$ = psCurrBlock;
				}
			|	floatexp LESSEQUAL floatexp
				{
					codeRet = scriptCodeBinaryOperator($1, $3, OP_LESSEQUAL, &psCurrBlock);
					CHECK_CODE_ERROR(codeRet);

					/* Return the code block */
					$$ = psCurrBlock;
				}
			|	expression GREATEQUAL expression
				{
					codeRet = scriptCodeBinaryOperator($1, $3, OP_GREATEREQUAL, &psCurrBlock);
					CHECK_CODE_ERROR(codeRet);

					/* Return the code block */
					$$ = psCurrBlock;
				}
			|	floatexp GREATEQUAL floatexp
				{
					codeRet = scriptCodeBinaryOperator($1, $3, OP_GREATEREQUAL, &psCurrBlock);
					CHECK_CODE_ERROR(codeRet);

					/* Return the code block */
					$$ = psCurrBlock;
				}
			|	expression GREATER expression
				{
					codeRet = scriptCodeBinaryOperator($1, $3, OP_GREATER, &psCurrBlock);
					CHECK_CODE_ERROR(codeRet);

					/* Return the code block */
					$$ = psCurrBlock;
				}
			|	floatexp GREATER floatexp
				{
					codeRet = scriptCodeBinaryOperator($1, $3, OP_GREATER, &psCurrBlock);
					CHECK_CODE_ERROR(codeRet);

					/* Return the code block */
					$$ = psCurrBlock;
				}
			|	expression LESS expression
				{
					codeRet = scriptCodeBinaryOperator($1, $3, OP_LESS, &psCurrBlock);
					CHECK_CODE_ERROR(codeRet);

					/* Return the code block */
					$$ = psCurrBlock;
				}
			|	floatexp LESS floatexp
				{
					codeRet = scriptCodeBinaryOperator($1, $3, OP_LESS, &psCurrBlock);
					CHECK_CODE_ERROR(codeRet);

					/* Return the code block */
					$$ = psCurrBlock;
				}
			;

	/*************************************************************************************
	 *
	 * User variable expressions
	 */

userexp:		VAR
				{
					codeRet = scriptCodeVarGet($1, &psCurrBlock);
					CHECK_CODE_ERROR(codeRet);

					/* Return the code block */
					$$ = psCurrBlock;
				}
			|	USER_CONSTANT
				{
					RULE("userexp: USER_CONSTANT");

					codeRet = scriptCodeConstant($1, &psCurrBlock);
					CHECK_CODE_ERROR(codeRet);

					/* Return the code block */
					$$ = psCurrBlock;
				}
			|	user_objvar
				{
					codeRet = scriptCodeObjGet($1, &psCurrBlock);
					CHECK_CODE_ERROR(codeRet);
					/* Return the code block */
					$$ = psCurrBlock;
				}
			|	user_array_var
				{
					RULE("userexp: user_array_var");
					
					codeRet = scriptCodeArrayGet($1, &psCurrBlock);
					CHECK_CODE_ERROR(codeRet);

					/* Return the code block */
					$$ = psCurrBlock;
				}
			|	USER_FUNC '(' param_list ')'
				{
					/* Generate the code for the function call */
					codeRet = scriptCodeFunction($1, $3, true, &psCurrBlock);
					CHECK_CODE_ERROR(codeRet);

					/* Return the code block */
					$$ = psCurrBlock;
				}
			|	USER_FUNC_CUST '(' param_list ')'
				{
						UDWORD line,paramNumber;
						char *pDummy;

						if($3->numParams != $1->numParams)
						{
							debug(LOG_ERROR, "Wrong number of arguments for function call: '%s'. Expected %d parameters instead of  %d.", $1->pIdent, $1->numParams, $3->numParams);
							scr_error("Wrong number of arguments in function call");
							return CE_PARSE;
						}

						if(!$1->bFunction)
						{
							debug(LOG_ERROR, "'%s' is not a function", $1->pIdent);
							scr_error("Can't call an event");
							return CE_PARSE;
						}

						/* check if right parameters were passed */
						paramNumber = checkFuncParamTypes($1, $3);
						if(paramNumber > 0)
						{
							debug(LOG_ERROR, "Parameter mismatch in function call: '%s'. Mismatch in parameter  %d.", $1->pIdent, paramNumber);
							YYABORT;
						}

						/* Allocate the code block */
						ALLOC_BLOCK(psCurrBlock, $3->size + 1 + 1);	//Params + Opcode + event index

						ALLOC_DEBUG(psCurrBlock, 1);
						ip = psCurrBlock->pCode;

						if($3->numParams > 0)	/* if any parameters declared */
						{
							/* Copy in the code for the parameters */
							PUT_BLOCK(ip, $3);
							FREE_PBLOCK($3);
						}

						/* Store the instruction */
						PUT_OPCODE(ip, OP_FUNC);
						PUT_EVENT(ip,$1->index);			//Put event index

						/* Add the debugging information */
						if (genDebugInfo)
						{
							psCurrBlock->psDebug[0].offset = 0;
							scriptGetErrorData((SDWORD *)&line, &pDummy);
							psCurrBlock->psDebug[0].line = line;
						}

						/* remember objexp type for further stuff, like myVar = objFunc(); to be able to check type equivalency */
						psCurrBlock->type = $1->retType;

						$$ = psCurrBlock;
				}
			|	TRIG_SYM
				{
					//ALLOC_BLOCK(psCurrBlock, sizeof(OPCODE) + sizeof(UDWORD));
					ALLOC_BLOCK(psCurrBlock, 1 + 1);	//opcode + trigger index

					ip = psCurrBlock->pCode;

					/* Code to store the value on the stack */
					PUT_PKOPCODE(ip, OP_PUSH, VAL_TRIGGER);		//TODO: don't need to put VAL_TRIGGER here, since stored in ip->type now
					PUT_TRIGGER(ip, $1->index);

					psCurrBlock->type = VAL_TRIGGER;

					/* Return the code block */
					$$ = psCurrBlock;
				}
			|	INACTIVE
				{
					//ALLOC_BLOCK(psCurrBlock, sizeof(OPCODE) + sizeof(UDWORD));
					ALLOC_BLOCK(psCurrBlock, 1 + 1);	//opcode + '-1' for 'inactive'

					ip = psCurrBlock->pCode;

					/* Code to store the value on the stack */
					PUT_PKOPCODE(ip, OP_PUSH, VAL_TRIGGER);
					PUT_TRIGGER(ip, -1);

					psCurrBlock->type = VAL_TRIGGER;

					/* Return the code block */
					$$ = psCurrBlock;
				}
			|	EVENT_SYM
				{
					//ALLOC_BLOCK(psCurrBlock, sizeof(OPCODE) + sizeof(UDWORD));
					ALLOC_BLOCK(psCurrBlock, 1 + 1);	//opcode + event index

					ip = psCurrBlock->pCode;

					/* Code to store the value on the stack */
					PUT_PKOPCODE(ip, OP_PUSH, VAL_EVENT);
					PUT_EVENT(ip, $1->index);

					psCurrBlock->type = VAL_EVENT;

					/* Return the code block */
					$$ = psCurrBlock;
				}
			;

	/*************************************************************************************
	 *
	 * Object expressions.
	 */

objexp:			OBJ_VAR
				{
					codeRet = scriptCodeVarGet($1, &psCurrBlock);
					CHECK_CODE_ERROR(codeRet);

					/* Return the code block */
					$$ = psCurrBlock;
				}
			|	OBJ_CONSTANT
				{
					RULE("objexp: OBJ_CONSTANT");

					codeRet = scriptCodeConstant($1, &psCurrBlock);
					CHECK_CODE_ERROR(codeRet);

					/* Return the code block */
					$$ = psCurrBlock;
				}
			|	OBJ_FUNC '(' param_list ')'
				{
					/* Generate the code for the function call */
					codeRet = scriptCodeFunction($1, $3, true, &psCurrBlock);
					CHECK_CODE_ERROR(codeRet);

					/* Return the code block */
					$$ = psCurrBlock;
				}
			|	OBJ_FUNC_CUST '(' param_list ')'
				{
						UDWORD paramNumber;

						if($3->numParams != $1->numParams)
						{
							debug(LOG_ERROR, "Wrong number of arguments for function call: '%s'. Expected %d parameters instead of  %d.", $1->pIdent, $1->numParams, $3->numParams);
							scr_error("Wrong number of arguments in function call");
							return CE_PARSE;
						}

						if(!$1->bFunction)
						{
							debug(LOG_ERROR, "'%s' is not a function", $1->pIdent);
							scr_error("Can't call an event");
							return CE_PARSE;
						}

						/* make sure function has a return type */
						/* if($1->retType != OBJ_VAR) */
						if(asScrTypeTab[$1->retType - VAL_USERTYPESTART].accessType != AT_OBJECT)
						{
							scr_error("'%s' does not return an object value (%d )", $1->pIdent, $1->retType);
							return CE_PARSE;
						}

						/* check if right parameters were passed */
						paramNumber = checkFuncParamTypes($1, $3);
						if(paramNumber > 0)
						{
							debug(LOG_ERROR, "Parameter mismatch in function call: '%s'. Mismatch in parameter  %d.", $1->pIdent, paramNumber);
							YYABORT;
						}

						/* Allocate the code block */
						ALLOC_BLOCK(psCurrBlock, $3->size + 1 + 1);	//Params + Opcode + event index

						ip = psCurrBlock->pCode;

						if($3->numParams > 0)	/* if any parameters declared */
						{
							/* Copy in the code for the parameters */
							PUT_BLOCK(ip, $3);
						}

						FREE_PBLOCK($3);

						/* Store the instruction */
						PUT_OPCODE(ip, OP_FUNC);
						PUT_EVENT(ip,$1->index);			//Put event index

						/* remember objexp type for further stuff, like myVar = objFunc(); to be able to check type equivalency */
						psCurrBlock->type = $1->retType;

						$$ = psCurrBlock;
				}
			|	obj_objvar
				{
					codeRet = scriptCodeObjGet($1, &psCurrBlock);
					CHECK_CODE_ERROR(codeRet);

					/* Return the code block */
					$$ = psCurrBlock;
				}
			|	obj_array_var
				{
					codeRet = scriptCodeArrayGet($1, &psCurrBlock);
					CHECK_CODE_ERROR(codeRet);

					/* Return the code block */
					$$ = psCurrBlock;
				}
			;

	/*
	 * Seperate rule for the dot after an object so the lookup context
	 * for object variables can be set
	 */
objexp_dot:		objexp '.'
				{
					RULE( "objexp_dot: objexp '.', type=%d", $1->type);

					// Store the object type for the variable lookup
					objVarContext = $1->type;
				}
			|
				userexp '.'
				{
					RULE( "objexp_dot: userexp '.', type=%d", $1->type);

					// Store the object type for the variable lookup
					objVarContext = $1->type;
				}
			;

	/*
	 * Object member variable references.
	 */

num_objvar:		objexp_dot NUM_OBJVAR
				{

					RULE( "num_objvar: objexp_dot NUM_OBJVAR");

					codeRet = scriptCodeObjectVariable($1, $2, &psObjVarBlock);
					CHECK_CODE_ERROR(codeRet);

					// reset the object type
					objVarContext = 0;

					/* Return the code block */
					$$ = psObjVarBlock;
				}
			;

bool_objvar:	objexp_dot BOOL_OBJVAR
				{
					codeRet = scriptCodeObjectVariable($1, $2, &psObjVarBlock);
					CHECK_CODE_ERROR(codeRet);

					// reset the object type
					objVarContext = 0;

					/* Return the code block */
					$$ = psObjVarBlock;
				}
			;

user_objvar:	objexp_dot USER_OBJVAR
				{
					codeRet = scriptCodeObjectVariable($1, $2, &psObjVarBlock);
					CHECK_CODE_ERROR(codeRet);

					// reset the object type
					objVarContext = 0;

					/* Return the code block */
					$$ = psObjVarBlock;
				}
			;
obj_objvar:		objexp_dot OBJ_OBJVAR
				{
					codeRet = scriptCodeObjectVariable($1, $2, &psObjVarBlock);
					CHECK_CODE_ERROR(codeRet);

					// reset the object type
					objVarContext = 0;

					/* Return the code block */
					$$ = psObjVarBlock;
				}
			;

	/*****************************************************************************************************
	 *
	 * Array expressions
	 *
	 */

array_index:		'[' expression ']'
					{
						ALLOC_ARRAYBLOCK(psCurrArrayBlock, $2->size, NULL);
						ip = psCurrArrayBlock->pCode;

						/* Copy the index expression code into the code block */
						PUT_BLOCK(ip, $2);
						FREE_BLOCK($2);

						$$ = psCurrArrayBlock;
					}
			;

array_index_list:	array_index
					{
						$$ = $1;
					}
				|
					array_index_list '[' expression ']'
					{
						ALLOC_ARRAYBLOCK(psCurrArrayBlock, $1->size + $3->size, NULL);

						ip = psCurrArrayBlock->pCode;

						/* Copy the index expression code into the code block */
						psCurrArrayBlock->dimensions = $1->dimensions + 1;
						PUT_BLOCK(ip, $1);
						PUT_BLOCK(ip, $3);
						FREE_ARRAYBLOCK($1);
						FREE_ARRAYBLOCK($3);

						$$ = psCurrArrayBlock;
					}
				;

num_array_var:		NUM_ARRAY array_index_list
					{
						codeRet = scriptCodeArrayVariable($2, $1, &psCurrArrayBlock);
						CHECK_CODE_ERROR(codeRet);

						/* Return the code block */
						$$ = psCurrArrayBlock;
					}
				;

bool_array_var:		BOOL_ARRAY array_index_list
					{
						codeRet = scriptCodeArrayVariable($2, $1, &psCurrArrayBlock);
						CHECK_CODE_ERROR(codeRet);

						/* Return the code block */
						$$ = psCurrArrayBlock;
					}
				;

obj_array_var:		OBJ_ARRAY array_index_list
					{
						codeRet = scriptCodeArrayVariable($2, $1, &psCurrArrayBlock);
						CHECK_CODE_ERROR(codeRet);

						/* Return the code block */
						$$ = psCurrArrayBlock;
					}
				;

user_array_var:		VAR_ARRAY array_index_list
					{
						RULE("user_array_var:		VAR_ARRAY array_index_list");
						
						codeRet = scriptCodeArrayVariable($2, $1, &psCurrArrayBlock);
						CHECK_CODE_ERROR(codeRet);

						/* Return the code block */
						$$ = psCurrArrayBlock;
					}
				;

%%

// Reset all the symbol tables
static void scriptResetTables(void)
{
	VAR_SYMBOL		*psCurr, *psNext;
	TRIGGER_SYMBOL	*psTCurr, *psTNext;
	EVENT_SYMBOL	*psECurr, *psENext;

	SDWORD			i;

	/* start with global vars definition */
	localVariableDef = false;
	//debug(LOG_SCRIPT, "localVariableDef = false 4");

	/* Reset the global variable symbol table */
	for(psCurr = psGlobalVars; psCurr != NULL; psCurr = psNext)
	{
		psNext = psCurr->psNext;
		free(psCurr);
	}
	psGlobalVars = NULL;

	/* Reset the global variable symbol table */
	psCurEvent = NULL;
	for(i=0; i<maxEventsLocalVars; i++)
	{
		numEventLocalVars[i] = 0;

		for(psCurr = psLocalVarsB[i]; psCurr != NULL; psCurr = psNext)
		{
			psNext = psCurr->psNext;
			free(psCurr);
		}
		psLocalVarsB[i] = NULL;
	}

	/* Reset the global array symbol table */
	for(psCurr = psGlobalArrays; psCurr != NULL; psCurr = psNext)
	{
		psNext = psCurr->psNext;
		free(psCurr);
	}
	psGlobalArrays = NULL;

	// Reset the trigger table
	for(psTCurr = psTriggers; psTCurr; psTCurr = psTNext)
	{
		psTNext = psTCurr->psNext;
		if (psTCurr->psDebug)
		{
			free(psTCurr->psDebug);
		}
		if (psTCurr->pCode)
		{
			free(psTCurr->pCode);
		}
		free(psTCurr->pIdent);
		free(psTCurr);
	}
	psTriggers = NULL;
	numTriggers = 0;

	// Reset the event table
	for(psECurr = psEvents; psECurr; psECurr = psENext)
	{
		psENext = psECurr->psNext;
		if (psECurr->psDebug)
		{
			free(psECurr->psDebug);
		}
		free(psECurr->pIdent);
		free(psECurr->pCode);
		free(psECurr);
	}
	psEvents = NULL;
	numEvents = 0;
}

/* Compile a script program */
SCRIPT_CODE* scriptCompile(PHYSFS_file* fileHandle, SCR_DEBUGTYPE debugType)
{
	/* Feed flex with initial input buffer */
	scriptSetInputFile(fileHandle);

	scriptResetTables();
	psFinalProg = NULL;
	if (debugType == SCR_DEBUGINFO)
	{
		genDebugInfo = true;
	}
	else
	{
		genDebugInfo = false;
	}

	if (scr_parse() != 0 || bError)
	{
		scr_lex_destroy();
		return NULL;
	}
	scr_lex_destroy();

	scriptResetTables();

	return psFinalProg;
}


/* A simple error reporting routine */
void scr_error(const char *pMessage, ...)
{
	int		line;
	char	*text;
	va_list	args;
	char	aBuff[1024];

	va_start(args, pMessage);
	vsnprintf(aBuff, sizeof(aBuff), pMessage, args);
	va_end(args);

	scriptGetErrorData(&line, &text);

	bError = true;

#ifdef DEBUG
	debug( LOG_ERROR, "script parse error:\n%s at %s:%d\nToken: %d, Text: '%s'\n",
			  aBuff, GetLastResourceFilename(), line, scr_char, text );
	ASSERT( false, "script parse error:\n%s at %s:%d\nToken: %d, Text: '%s'\n",
			  aBuff, GetLastResourceFilename(), line, scr_char, text );
#else
	//DBERROR(("script parse error:\n%s at line %d\nToken: %d, Text: '%s'\n",
	//		  pMessage, line, scr_char, text));
	debug( LOG_ERROR, "script parse error:\n'%s' at %s:%d\nToken: %d, Text: '%s'\n",
			  aBuff, GetLastResourceFilename(), line, scr_char, text );
	abort();
#endif
}


/* Look up a type symbol */
BOOL scriptLookUpType(const char *pIdent, INTERP_TYPE *pType)
{
	UDWORD	i;

	//debug(LOG_SCRIPT, "scriptLookUpType");

	if (asScrTypeTab)
	{
		for(i=0; asScrTypeTab[i].typeID != 0; i++)
		{
			if (strcmp(asScrTypeTab[i].pIdent, pIdent) == 0)
			{
				*pType = asScrTypeTab[i].typeID;
				return true;
			}
		}
	}

	//debug(LOG_SCRIPT, "END scriptLookUpType");

	return false;
}

/* pop passed arguments (if any) */
BOOL popArguments(INTERP_VAL **ip_temp, SDWORD numParams)
{
	SDWORD			i;

	/* code to pop passed params right before the main code begins */
	for(i = numParams-1; i >= 0 ; i--)
	{
		PUT_PKOPCODE(*ip_temp, OP_POPLOCAL, i);		//pop parameters into first i local params
	}

	return true;
}


/* Add a new variable symbol.
 * If localVariableDef is true a local variable symbol is defined,
 * otherwise a global variable symbol is defined.
 */
BOOL scriptAddVariable(VAR_DECL *psStorage, VAR_IDENT_DECL *psVarIdent)
{
	VAR_SYMBOL		*psNew;
	unsigned int i;
	char* ident;

	/* Allocate the memory for the symbol structure plus the symbol name */
	psNew = (VAR_SYMBOL *)malloc(sizeof(VAR_SYMBOL) + strlen(psVarIdent->pIdent) + 1);
	if (psNew == NULL)
	{
		scr_error("Out of memory");
		return false;
	}

	// This ensures we only need to call free() on the VAR_SYMBOL* pointer and not on its members
	ident = (char*)(psNew + 1);
	strcpy(ident, psVarIdent->pIdent);
	psNew->pIdent = ident;

	psNew->type = psStorage->type;
	psNew->storage = psStorage->storage;
	psNew->dimensions = psVarIdent->dimensions;


	for(i=0; i<psNew->dimensions; i++)
	{
		psNew->elements[i] = psVarIdent->elements[i];
	}
	if (psNew->dimensions == 0)
	{
		if(psStorage->storage != ST_LOCAL)	//if not a local var
		{
			if (psGlobalVars == NULL)
			{
				psNew->index = 0;
			}
			else
			{
				psNew->index = psGlobalVars->index + 1;
			}

			/* Add the symbol to the list */
			psNew->psNext = psGlobalVars;
			psGlobalVars = psNew;
		}
		else		//local var
		{
			if(psCurEvent == NULL)
				debug(LOG_ERROR, "Can't declare local variables before defining an event");

			//debug(LOG_SCRIPT, "local variable declared for event %d, type=%d \n", psCurEvent->index, psNew->type);
			//debug(LOG_SCRIPT, "%s \n", psNew->pIdent);

			if (psLocalVarsB[psCurEvent->index] == NULL)
			{
				psNew->index = 0;
			}
			else
			{
				psNew->index = psLocalVarsB[psCurEvent->index]->index + 1;
			}

			numEventLocalVars[psCurEvent->index] = numEventLocalVars[psCurEvent->index] + 1;

			psNew->psNext = psLocalVarsB[psCurEvent->index];
			psLocalVarsB[psCurEvent->index] = psNew;

			//debug(LOG_SCRIPT, "local variable declared. ");
		}
	}
	else
	{
		if (psGlobalArrays == NULL)
		{
			psNew->index = 0;
		}
		else
		{
			psNew->index = psGlobalArrays->index + 1;
		}

		psNew->psNext = psGlobalArrays;
		psGlobalArrays = psNew;
	}


	return true;
}

/* Look up a variable symbol */
BOOL scriptLookUpVariable(const char *pIdent, VAR_SYMBOL **ppsSym)
{
	VAR_SYMBOL		*psCurr;
	UDWORD			i;

	//debug(LOG_SCRIPT, "scriptLookUpVariable");

	/* See if the symbol is an object variable */
	if (asScrObjectVarTab && objVarContext != 0)
	{
		for(psCurr = asScrObjectVarTab; psCurr->pIdent != NULL; psCurr++)
		{
			if (interpCheckEquiv(psCurr->objType, objVarContext) &&
				strcmp(psCurr->pIdent, pIdent) == 0)
			{
				*ppsSym = psCurr;
				return true;
			}
		}
	}

	/* See if the symbol is an external variable */
	if (asScrExternalTab)
	{
		for(psCurr = asScrExternalTab; psCurr->pIdent != NULL; psCurr++)
		{
			if (strcmp(psCurr->pIdent, pIdent) == 0)
			{
				//debug(LOG_SCRIPT, "scriptLookUpVariable: extern");
				*ppsSym = psCurr;
				return true;
			}
		}
	}

	/* check local vars if we are inside of an event */
	if(psCurEvent != NULL)
	{
		if(psCurEvent->index >= maxEventsLocalVars)
			debug(LOG_ERROR, "psCurEvent->index (%d) >= maxEventsLocalVars", psCurEvent->index);

		i = psCurEvent->index;

		if(psLocalVarsB[i] != NULL)	//any vars stored for this event
		{
		int		line;
		char	*text;

			//debug(LOG_SCRIPT, "now checking event %s; index = %d\n", psCurEvent->pIdent, psCurEvent->index);
			scriptGetErrorData(&line, &text);
			for(psCurr = psLocalVarsB[i]; psCurr != NULL; psCurr = psCurr->psNext)
			{

				if(psCurr->pIdent == NULL)
				{
					debug(LOG_ERROR, "psCurr->pIdent == NULL");
					debug(LOG_ERROR, "psCurr->index = %d", psCurr->index);
				}

				//debug(LOG_SCRIPT, "start comparing, num local vars=%d, at line %d\n", numEventLocalVars[i], line);
				//debug(LOG_SCRIPT, "current var=%s\n", psCurr->pIdent);
				//debug(LOG_SCRIPT, "passed string=%s\n", pIdent);

				//debug(LOG_SCRIPT, "comparing %s with %s \n", psCurr->pIdent, pIdent);
				if (strcmp(psCurr->pIdent, pIdent) == 0)
				{
					//debug(LOG_SCRIPT, "scriptLookUpVariable - local var found, type=%d\n", psCurr->type);
					*ppsSym = psCurr;
					return true;
				}
			}
		}
	}

	/* See if the symbol is in the global variable list.
	 * This is not checked for when local variables are being defined.
	 * This allows local variables to have the same name as global ones.
	 */
	if (!localVariableDef)
	{
		for(psCurr = psGlobalVars; psCurr != NULL; psCurr = psCurr->psNext)
		{
			if (strcmp(psCurr->pIdent, pIdent) == 0)
			{
				*ppsSym = psCurr;
				return true;
			}
		}
		for(psCurr = psGlobalArrays; psCurr != NULL; psCurr = psCurr->psNext)
		{
			if (strcmp(psCurr->pIdent, pIdent) == 0)
			{
				*ppsSym = psCurr;
				return true;
			}
		}
	}

	/* Failed to find the variable */
	*ppsSym = NULL;

	//debug(LOG_SCRIPT, "END scriptLookUpVariable");
	return false;
}


/* Add a new trigger symbol */
BOOL scriptAddTrigger(const char *pIdent, TRIGGER_DECL *psDecl, UDWORD line)
{
	TRIGGER_SYMBOL		*psTrigger, *psCurr, *psPrev;

	// Allocate the trigger
	psTrigger = malloc(sizeof(TRIGGER_SYMBOL));
	if (!psTrigger)
	{
		scr_error("Out of memory");
		return false;
	}
	psTrigger->pIdent = malloc(strlen(pIdent) + 1);
	if (!psTrigger->pIdent)
	{
		scr_error("Out of memory");
		return false;
	}
	strcpy(psTrigger->pIdent, pIdent);
	if (psDecl->size > 0)
	{
		psTrigger->pCode = (INTERP_VAL *)malloc(psDecl->size * sizeof(INTERP_VAL));
		if (!psTrigger->pCode)
		{
			scr_error("Out of memory");
			return false;
		}
		memcpy(psTrigger->pCode, psDecl->pCode, psDecl->size * sizeof(INTERP_VAL));
	}
	else
	{
		psTrigger->pCode = NULL;
	}
	psTrigger->size = psDecl->size;
	psTrigger->type = psDecl->type;
	psTrigger->time = psDecl->time;
	psTrigger->index = numTriggers++;
	psTrigger->psNext = NULL;

	// Add debug info
	if (genDebugInfo)
	{
		psTrigger->psDebug = malloc(sizeof(SCRIPT_DEBUG));
		psTrigger->psDebug[0].offset = 0;
		psTrigger->psDebug[0].line = line;
		psTrigger->debugEntries = 1;
	}
	else
	{
		psTrigger->debugEntries = 0;
		psTrigger->psDebug = NULL;
	}


	// Store the trigger
	psPrev = NULL;
	for(psCurr = psTriggers; psCurr; psCurr = psCurr->psNext)
	{
		psPrev = psCurr;
	}
	if (psPrev)
	{
		psPrev->psNext = psTrigger;
	}
	else
	{
		psTriggers = psTrigger;
	}

	return true;
}


/* Lookup a trigger symbol */
BOOL scriptLookUpTrigger(const char *pIdent, TRIGGER_SYMBOL **ppsTrigger)
{
	TRIGGER_SYMBOL	*psCurr;

	//debug(LOG_SCRIPT, "scriptLookUpTrigger");

	for(psCurr = psTriggers; psCurr; psCurr=psCurr->psNext)
	{
		if (strcmp(pIdent, psCurr->pIdent) == 0)
		{
			//debug(LOG_SCRIPT, "scriptLookUpTrigger: found");
			*ppsTrigger = psCurr;
			return true;
		}
	}

	//debug(LOG_SCRIPT, "END scriptLookUpTrigger");

	return false;
}


/* Lookup a callback trigger symbol */
BOOL scriptLookUpCallback(const char *pIdent, CALLBACK_SYMBOL **ppsCallback)
{
	CALLBACK_SYMBOL		*psCurr;

	//debug(LOG_SCRIPT, "scriptLookUpCallback");

	if (!asScrCallbackTab)
	{
		return false;
	}

	for(psCurr = asScrCallbackTab; psCurr->type != 0; psCurr += 1)
	{
		if (strcmp(pIdent, psCurr->pIdent) == 0)
		{
			//debug(LOG_SCRIPT, "scriptLookUpCallback: found");
			*ppsCallback = psCurr;
			return true;
		}
	}

	//debug(LOG_SCRIPT, "END scriptLookUpCallback: found");
	return false;
}

/* Add a new event symbol */
BOOL scriptDeclareEvent(const char *pIdent, EVENT_SYMBOL **ppsEvent, SDWORD numArgs)
{
	EVENT_SYMBOL		*psEvent, *psCurr, *psPrev;

	// Allocate the event
	psEvent = malloc(sizeof(EVENT_SYMBOL));
	if (!psEvent)
	{
		scr_error("Out of memory");
		return false;
	}
	psEvent->pIdent = malloc(strlen(pIdent) + 1);
	if (!psEvent->pIdent)
	{
		scr_error("Out of memory");
		return false;
	}
	strcpy(psEvent->pIdent, pIdent);
	psEvent->pCode = NULL;
	psEvent->size = 0;
	psEvent->psDebug = NULL;
	psEvent->debugEntries = 0;
	psEvent->index = numEvents++;
	psEvent->psNext = NULL;

	/* remember how many params this event has */
	psEvent->numParams = numArgs;
	psEvent->bFunction = false;
	psEvent->bDeclared = false;
	psEvent->retType = VAL_VOID;	/* functions can return a value */

	// Add the event to the list
	psPrev = NULL;
	for(psCurr = psEvents; psCurr; psCurr = psCurr->psNext)
	{
		psPrev = psCurr;
	}
	if (psPrev)
	{
		psPrev->psNext = psEvent;
	}
	else
	{
		psEvents = psEvent;
	}

	*ppsEvent = psEvent;

	return true;
}

// Add the code to a defined event
BOOL scriptDefineEvent(EVENT_SYMBOL *psEvent, CODE_BLOCK *psCode, SDWORD trigger)
{
	ASSERT(psCode != NULL, "scriptDefineEvent: psCode == NULL");
	ASSERT(psCode->size > 0,
		"Event '%s' is empty, please add at least 1 statement", psEvent->pIdent);

	// events with arguments can't have a trigger assigned
	ASSERT(!(psEvent->numParams > 0 && trigger >= 0),
		"Events with parameters can't have a trigger assigned, event: '%s' ", psEvent->pIdent);

	// Store the event code
	psEvent->pCode = (INTERP_VAL *)malloc(psCode->size * sizeof(INTERP_VAL));
	if (!psEvent->pCode)
	{
		scr_error("Out of memory");
		return false;
	}

	memcpy(psEvent->pCode, psCode->pCode, psCode->size * sizeof(INTERP_VAL));
	psEvent->size = psCode->size;
	psEvent->trigger = trigger;

	// Add debug info
	if (genDebugInfo && (psCode->debugEntries > 0))
	{
		psEvent->psDebug = malloc(sizeof(SCRIPT_DEBUG) * psCode->debugEntries);

		if (!psEvent->psDebug)
		{
			scr_error("Out of memory");
			return false;
		}

		memcpy(psEvent->psDebug, psCode->psDebug,
			sizeof(SCRIPT_DEBUG) * psCode->debugEntries);
		psEvent->debugEntries = psCode->debugEntries;
	}
	else
	{
		psEvent->debugEntries = 0;
		psEvent->psDebug = NULL;
	}

	//debug(LOG_SCRIPT, "before define event");

	/* store local vars */
	if(psEvent->index >= maxEventsLocalVars)
		debug(LOG_ERROR, "scriptDefineEvent - psEvent->index >= maxEventsLocalVars");

	return true;
}

/* Lookup an event symbol */
BOOL scriptLookUpEvent(const char *pIdent, EVENT_SYMBOL **ppsEvent)
{
	EVENT_SYMBOL	*psCurr;
	//debug(LOG_SCRIPT, "scriptLookUpEvent");

	for(psCurr = psEvents; psCurr; psCurr=psCurr->psNext)
	{
		if (strcmp(pIdent, psCurr->pIdent) == 0)
		{
			//debug(LOG_SCRIPT, "scriptLookUpEvent:found");
			*ppsEvent = psCurr;
			return true;
		}
	}
	//debug(LOG_SCRIPT, "END scriptLookUpEvent");
	return false;
}


/* Look up a constant variable symbol */
BOOL scriptLookUpConstant(const char *pIdent, CONST_SYMBOL **ppsSym)
{
	CONST_SYMBOL	*psCurr;

	//debug(LOG_SCRIPT, "scriptLookUpConstant");

	/* Scan the Constant list */
	if (asScrConstantTab)
	{
		for(psCurr = asScrConstantTab; psCurr->type != VAL_VOID; psCurr++)
		{
			if (strcmp(psCurr->pIdent, pIdent) == 0)
			{
				*ppsSym = psCurr;
				return true;
			}
		}
	}

	//debug(LOG_SCRIPT, "END scriptLookUpConstant");

	return false;
}


/* Look up a function symbol */
BOOL scriptLookUpFunction(const char *pIdent, FUNC_SYMBOL **ppsSym)
{
	UDWORD i;

	//debug(LOG_SCRIPT, "scriptLookUpFunction");

	/* See if the function is defined as an instinct function */
	if (asScrInstinctTab)
	{
		for(i = 0; asScrInstinctTab[i].pFunc != NULL; i++)
		{
			if (strcmp(asScrInstinctTab[i].pIdent, pIdent) == 0)
			{
				*ppsSym = asScrInstinctTab + i;
				return true;
			}
		}
	}

	/* Failed to find the indentifier */
	*ppsSym = NULL;

	//debug(LOG_SCRIPT, "END scriptLookUpFunction");
	return false;
}

/* Look up a function symbol defined in script */
BOOL scriptLookUpCustomFunction(const char *pIdent, EVENT_SYMBOL **ppsSym)
{
	EVENT_SYMBOL	*psCurr;

	//debug(LOG_SCRIPT, "scriptLookUpCustomFunction");

	/* See if the function is defined as a script function */
	for(psCurr = psEvents; psCurr; psCurr = psCurr->psNext)
	{
		if(psCurr->bFunction)	/* event defined as function */
		{
			if (strcmp(psCurr->pIdent, pIdent) == 0)
			{
				//debug(LOG_SCRIPT, "scriptLookUpCustomFunction: %s is a custom function", pIdent);
				*ppsSym = psCurr;
				return true;
			}
		}
	}

	/* Failed to find the indentifier */
	*ppsSym = NULL;

	//debug(LOG_SCRIPT, "END scriptLookUpCustomFunction");
	return false;
}


/* Set the type table */
void scriptSetTypeTab(TYPE_SYMBOL *psTypeTab)
{
#ifdef DEBUG
	SDWORD			i;
	INTERP_TYPE		type;

	for(i=0, type=VAL_USERTYPESTART; psTypeTab[i].typeID != 0; i++)
	{
		ASSERT( psTypeTab[i].typeID == type,
			"scriptSetTypeTab: ID's must be >= VAL_USERTYPESTART and sequential" );
		type = type + 1;
	}
#endif

	asScrTypeTab = psTypeTab;
}


/* Set the function table */
void scriptSetFuncTab(FUNC_SYMBOL *psFuncTab)
{
	asScrInstinctTab = psFuncTab;
}

/* Set the object variable table */
void scriptSetObjectTab(VAR_SYMBOL *psObjTab)
{
	asScrObjectVarTab = psObjTab;
}

/* Set the external variable table */
void scriptSetExternalTab(VAR_SYMBOL *psExtTab)
{
	asScrExternalTab = psExtTab;
}

/* Set the constant table */
void scriptSetConstTab(CONST_SYMBOL *psConstTab)
{
	asScrConstantTab = psConstTab;
}

/* Set the callback table */
void scriptSetCallbackTab(CALLBACK_SYMBOL *psCallTab)
{
#ifdef DEBUG
	SDWORD			i;
	TRIGGER_TYPE	type;

	for(i=0, type=TR_CALLBACKSTART; psCallTab[i].type != 0; i++)
	{
		ASSERT( psCallTab[i].type == type,
			"scriptSetCallbackTab: ID's must be >= VAL_CALLBACKSTART and sequential" );
		type = type + 1;
	}
#endif

	asScrCallbackTab = psCallTab;
}
