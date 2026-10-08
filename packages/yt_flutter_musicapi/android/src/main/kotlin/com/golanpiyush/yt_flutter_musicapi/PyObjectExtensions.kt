// PyObjectExtensions.kt
package com.golanpiyush.yt_flutter_musicapi

import com.chaquo.python.PyObject
import com.chaquo.python.Python

internal val PyObject.isNone: Boolean
    get() = this.toString() == "None"

internal val PyObject.isTrue: Boolean
    get() = this.toString() == "True"

internal val PyObject.isFalse: Boolean
    get() = this.toString() == "False"

internal val PyObject.isString: Boolean
    get() = try {
        Python.getInstance().getBuiltins()
            .callAttr("isinstance", this, Python.getInstance().getBuiltins().get("str"))
            .toBoolean() 
    } catch (e: Exception) {
        false
    }

internal val PyObject.isNumber: Boolean
    get() = try {
        Python.getInstance().getBuiltins()
            .callAttr("isinstance", this, Python.getInstance().getBuiltins().get("int"))
            .toBoolean()  ||
        Python.getInstance().getBuiltins()
            .callAttr("isinstance", this, Python.getInstance().getBuiltins().get("float"))
            .toBoolean() 
    } catch (e: Exception) {
        false
    }



    