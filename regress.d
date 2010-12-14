/**A module for performing linear regression.  This module has an unusual
 * interface, as it is range-based instead of matrix based. Values for
 * independent variables are provided as either a tuple or a range of ranges.
 * This means that one can use, for example, map, to fit high order models and
 * lazily evaluate certain values.  (For details, see examples below.)
 *
 * Author:  David Simcha*/
 /*
 * License:
 * Boost Software License - Version 1.0 - August 17th, 2003
 *
 * Permission is hereby granted, free of charge, to any person or organization
 * obtaining a copy of the software and accompanying documentation covered by
 * this license (the "Software") to use, reproduce, display, distribute,
 * execute, and transmit the Software, and to prepare derivative works of the
 * Software, and to permit third-parties to whom the Software is furnished to
 * do so, all subject to the following:
 *
 * The copyright notices in the Software and this entire statement, including
 * the above license grant, this restriction and the following disclaimer,
 * must be included in all copies of the Software, in whole or in part, and
 * all derivative works of the Software, unless such copies or derivative
 * works are solely in the form of machine-executable object code generated by
 * a source language processor.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE, TITLE AND NON-INFRINGEMENT. IN NO EVENT
 * SHALL THE COPYRIGHT HOLDERS OR ANYONE DISTRIBUTING THE SOFTWARE BE LIABLE
 * FOR ANY DAMAGES OR OTHER LIABILITY, WHETHER IN CONTRACT, TORT OR OTHERWISE,
 * ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */

module dstats.regress;

import std.math, std.algorithm, std.traits, std.array, std.traits, std.exception,
    std.typetuple, std.typecons;

import dstats.alloc, std.range, std.conv, dstats.distrib, dstats.cor, dstats.base;

private void enforceConfidence(double conf) {
    dstatsEnforce(conf >= 0 && conf <= 1,
        "Confidence intervals must be between 0 and 1.");
}

///
struct PowMap(ExpType, T)
if(isForwardRange!(T)) {
    Unqual!T range;
    Unqual!ExpType exponent;
    double cache;

    this(T range, ExpType exponent) {
        this.range = range;
        this.exponent = exponent;

        static if(isIntegral!ExpType) {
            cache = pow(cast(double) range.front, exponent);
        } else {
            cache = pow(cast(ExpType) range.front, exponent);
        }
    }

    @property double front() const pure nothrow {
        return cache;
    }

    void popFront() {
        range.popFront;
        if(!range.empty) {
            cache = pow(cast(double) range.front, exponent);
        }
    }

    @property typeof(this) save() {
        return this;
    }

    @property bool empty() {
        return range.empty;
    }
}

/**Maps a forward range to a power determined at runtime.  ExpType is the type
 * of the exponent.  Using an int is faster than using a double, but obviously
 * less flexible.*/
PowMap!(ExpType, T) powMap(ExpType, T)(T range, ExpType exponent) {
    alias PowMap!(ExpType, T) RT;
    return RT(range, exponent);
}

// Very ad-hoc, does a bunch of matrix ops.  Written specifically to be
// efficient in the context used here.
private void rangeMatrixMulTrans(U, T...)
(out double[] xTy, out double[][] xTx, U vec, T matIn) {
    static if(isArray!(T[0]) &&
        isInputRange!(typeof(matIn[0][0])) && matIn.length == 1) {
        alias typeof(matIn[0].front()) E;
        typeof(matIn[0]) mat = tempdup(cast(E[]) matIn[0]);
        scope(exit) TempAlloc.free;
    } else {
        alias matIn mat;
    }

    bool someEmpty() {
        if(vec.empty) {
            return true;
        }
        foreach(range; mat) {
            if(range.empty) {
                return true;
            }
        }
        return false;
    }

    void popAll() {
        foreach(ti, range; mat) {
            mat[ti].popFront;
        }
        vec.popFront;
    }

    xTy = newStack!double(mat.length);
    xTy[] = 0;

    xTx = newStack!(double[])(mat.length);
    foreach(ref elem; xTx) {
        elem = newStack!double(mat.length * 2);
    }

    foreach(row; xTx) {
        row[] = 0;
    }

    while(!someEmpty) {
        foreach(i, elem1; mat) {
            double e1Front = cast(double) elem1.front;
            xTy[i] += cast(double) elem1.front * cast(double) vec.front;
            xTx[i][i] += e1Front * e1Front;
            foreach(jMinusI, elem2; mat[i + 1..$]) {
                immutable j = i + 1 + jMinusI;
                double num = e1Front * cast(double) elem2.front;
                xTx[i][j] += num;
                xTx[j][i] += num;
            }
        }
        popAll;
    }
}

// Uses Gauss-Jordan elim. w/ row pivoting.  Not that efficient, but for the ad-hoc purposes
// it was meant for, it should be good enough.
void invert(ref double[][] mat) {
    // Normalize, augment w/ identity.  The matrix is already the right size
    // from rangeMatrixMulTrans.
    foreach(i, row; mat) {
        double absMax = 1.0L / reduce!(max)(map!(abs)(row[0..mat.length]));
        row[0..mat.length] *= absMax;
        row[i + mat.length] = absMax;
    }

    foreach(col; 0..mat.length) {
        size_t bestRow;
        double biggest = 0;
        foreach(row; col..mat.length) {
            if(abs(mat[row][col]) > biggest) {
                bestRow = row;
                biggest = abs(mat[row][col]);
            }
        }
        swap(mat[col], mat[bestRow]);

        foreach(row; 0..mat.length) {
            if(row == col) {
                continue;
            }
            double ratio = mat[row][col] / mat[col][col];
            foreach(i, ref elem; mat[row]) {
                elem -= mat[col][i] * ratio;
            }
        }
    }


    foreach(i; 0..mat.length) {
        double diagVal = mat[i][i];
        mat[i][] /= diagVal;
    }

    foreach(ref row; mat) {
        row = row[mat.length..$];
    }
}

/**Struct that holds the results of a linear regression.  It's a plain old
 * data struct.*/
struct RegressRes {
    /**The coefficients, one for each range in X.  These will be in the order
     * that the X ranges were passed in.*/
    double[] betas;

    /**The standard error terms of the X ranges passed in.*/
    double[] stdErr;

    /**The lower confidence bounds of the beta terms, at the confidence level
     * specificied.  (Default 0.95).*/
    double[] lowerBound;

    /**The upper confidence bounds of the beta terms, at the confidence level
     * specificied.  (Default 0.95).*/
    double[] upperBound;

    /**The P-value for the alternative that the corresponding beta value is
     * different from zero against the null that it is equal to zero.*/
    double[] p;

    /**The coefficient of determination.*/
    double R2;

    /**The adjusted coefficient of determination.*/
    double adjustedR2;

    /**The root mean square of the residuals.*/
    double residualError;

    /**The P-value for the model as a whole.  Based on an F-statistic.  The
     * null here is that the model has no predictive value, the alternative
     * is that it does.*/
    double overallP;

    // Just used internally.
    private static string arrStr(T)(T arr) {
        return text(arr)[1..$ - 1];
    }

    /**Print out the results in the default format.*/
    string toString() {
        return "Betas:  " ~ arrStr(betas) ~ "\nLower Conf. Int.:  " ~
            arrStr(lowerBound) ~ "\nUpper Conf. Int.:  " ~ arrStr(upperBound) ~
            "\nStd. Err:  " ~ arrStr(stdErr) ~ "\nP Values:  " ~ arrStr(p) ~
            "\nR^2:  " ~ text(R2) ~
            "\nAdjusted R^2:  " ~ text(adjustedR2) ~
            "\nStd. Residual Error:  " ~ text(residualError)
            ~ "\nOverall P:  " ~ text(overallP);
    }
}

/**Struct returned by polyFit.*/
struct PolyFitRes(T) {

    /**The array of PowMap ranges created by polyFit.*/
    T X;

    /**The rest of the results.  This is alias this'd.*/
    RegressRes regressRes;
    alias regressRes this;
}

/**Forward Range for holding the residuals from a regression analysis.*/
struct Residuals(F, U, T...) {
    static if(T.length == 1 && isForwardRange!(typeof(T[0].front()))) {
        alias T[0] R;
        alias typeof(array(R.init)) XType;
        enum bool needDup = true;
    } else {
        alias T R;
        alias staticMap!(Unqual, R) XType;
        enum bool needDup = false;
    }

    Unqual!U Y;
    XType X;
    F[] betas;
    double residual;
    bool _empty;

    void nextResidual() {
        double sum = 0;
        size_t i = 0;
        foreach(elem; X) {
            double frnt = elem.front;
            sum += frnt * betas[i];
            i++;
        }
        residual = Y.front - sum;
    }

    this(F[] betas, U Y, R X) {
        static if(is(typeof(X.length))) {
            dstatsEnforce(X.length == betas.length,
                "Betas and X must have same length for residuals.");
        } else {
            dstatsEnforce(walkLength(X) == betas.length,
                "Betas and X must have same length for residuals.");
        }

        static if(needDup) {
            this.X = array(X);
        } else {
            this.X = X;
        }

        foreach(i, elem; this.X) {
            static if(isForwardRange!(typeof(elem))) {
                this.X[i] = this.X[i].save;
            }
        }

        this.Y = Y;
        this.betas = betas;
        if(Y.empty) {
            _empty = true;
            return;
        }
        foreach(elem; X) {
            if(elem.empty) {
                _empty = true;
                return;
            }
        }
        nextResidual;
    }

    @property double front() const pure nothrow {
        return residual;
    }

    void popFront() {
        Y.popFront;
        if(Y.empty) {
            _empty = true;
            return;
        }
        foreach(ti, elem; X) {
            X[ti].popFront;
            if(X[ti].empty) {
                _empty = true;
                return;
            }
        }
        nextResidual;
    }

    @property bool empty() const pure nothrow {
        return _empty;
    }

    @property typeof(this) save() {
        auto ret = this;
        ret.Y = ret.Y.save;
        foreach(ti, xElem; ret.X) {
            ret.X[ti] = ret.X[ti].save;
        }

        return ret;
    }
}

/**Given the beta coefficients from a linear regression, and X and Y values,
 * returns a range that lazily computes the residuals.
 */
Residuals!(F, U, T) residuals(F, U, T...)(F[] betas, U Y, T X)
if(isFloatingPoint!F && isForwardRange!U && allSatisfy!(isForwardRange, T)) {
    alias Residuals!(F, U, T) RT;
    return RT(betas, Y, X);
}

/**Perform a linear regression and return just the beta values.  The advantages
 * to just returning the beta values are that it's faster and that each range
 * needs to be iterated over only once, and thus can be just an input range.
 * The beta values are returned such that the smallest index corresponds to
 * the leftmost element of X.  X can be either a tuple or a range of input
 * ranges.  Y must be an input range.
 *
 * Notes:  The X ranges are traversed in lockstep, but the traversal is stopped
 * at the end of the shortest one.  Therefore, using infinite ranges is safe.
 * For example, using repeat(1) to get an intercept term works.
 *
 * Examples:
 * ---
 * int[] nBeers = [8,6,7,5,3,0,9];
 * int[] nCoffees = [3,6,2,4,3,6,8];
 * int[] musicVolume = [3,1,4,1,5,9,2];
 * int[] programmingSkill = [2,7,1,8,2,8,1];
 * double[] betas = linearRegressBeta(programmingSkill, repeat(1), nBeers, nCoffees,
 *     musicVolume, map!"a * a"(musicVolume));
 * ---
 */
double[] linearRegressBeta(U, T...)(U Y, T XIn)
if(allSatisfy!(isInputRange, T) && doubleInput!(U)) {
    double[] dummy;
    return linearRegressBetaBuf!(U, T)(dummy, Y, XIn);
}

/**Same as linearRegressBeta, but allows the user to specify a buffer for
 * the beta terms.  If the buffer is too short, a new one is allocated.
 * Otherwise, the results are returned in the user-provided buffer.
 */
double[] linearRegressBetaBuf(U, T...)(double[] buf, U Y, T XIn)
if(allSatisfy!(isInputRange, T) && doubleInput!(U)) {
    mixin(newFrame);
    static if(isArray!(T[0]) && isInputRange!(typeof(XIn[0][0])) &&
        T.length == 1) {
        alias typeof(XIn[0].front) E;
        E[] X = tempdup(XIn[0]);
    } else {
        alias XIn X;
    }

    double[][] xTx;
    double[] xTy;
    rangeMatrixMulTrans(xTy, xTx, Y, X);
    invert(xTx);

    double[] ret;
    if(buf.length < X.length) {
        ret = new double[X.length];
    } else {
        ret = buf[0..X.length];
    }

    foreach(i; 0..ret.length) {
        ret[i] = 0;
        foreach(j; 0..ret.length) {
            ret[i] += xTx[i][j] * xTy[j];
        }
    }
    return ret;
}

/**Perform a linear regression as in linearRegressBeta, but return a
 * RegressRes with useful stuff for statistical inference.  If the last element
 * of input is a real, this is used to specify the confidence intervals to
 * be calculated.  Otherwise, the default of 0.95 is used.  The rest of input
 * should be the elements of X.
 *
 * When using this function, which provides several useful statistics useful
 * for inference, each range must be traversed twice.  This means:
 *
 * 1.  They have to be forward ranges, not input ranges.
 *
 * 2.  If you have a large amount of data and you're mapping it to some
 *     expensive function, you may want to do this eagerly instead of lazily.
 *
 * Notes:  The X ranges are traversed in lockstep, but the traversal is stopped
 * at the end of the shortest one.  Therefore, using infinite ranges is safe.
 * For example, using repeat(1) to get an intercept term works.
 *
 * Bugs:  The statistical tests performed in this function assume that an
 * intercept term is included in your regression model.  If no intercept term
 * is included, the P-values, confidence intervals and adjusted R^2 values
 * calculated by this function will be wrong.
 *
 * Examples:
 * ---
 * int[] nBeers = [8,6,7,5,3,0,9];
 * int[] nCoffees = [3,6,2,4,3,6,8];
 * int[] musicVolume = [3,1,4,1,5,9,2];
 * int[] programmingSkill = [2,7,1,8,2,8,1];
 *
 * // Using default confidence interval:
 * auto results = linearRegress(programmingSkill, repeat(1), nBeers, nCoffees,
 *     musicVolume, map!"a * a"(musicVolume));
 *
 * // Using user-specified confidence interval:
 * auto results = linearRegress(programmingSkill, repeat(1), nBeers, nCoffees,
 *     musicVolume, map!"a * a"(musicVolume), 0.8675309);
 * ---
 */
RegressRes linearRegress(U, TC...)(U Y, TC input) {
    static if(is(TC[$ - 1] : double)) {
        double confLvl = input[$ - 1];
        enforceConfidence(confLvl);
        alias TC[0..$ - 1] T;
        alias input[0..$ - 1] XIn;
    } else {
        double confLvl = 0.95; // Default;
        alias TC T;
        alias input XIn;
    }

    mixin(newFrame);
    static if(isForwardRange!(T[0]) && isForwardRange!(typeof(XIn[0].front())) &&
        T.length == 1) {

        enum bool arrayX = true;
        alias typeof(XIn[0].front) E;
        E[] X = tempdup(XIn[0]);
    } else static if(allSatisfy!(isForwardRange, T)) {
        enum bool arrayX = false;
        alias XIn X;
    } else {
        static assert(0, "Linear regression can only be performed with " ~
            "tuples of forward ranges or ranges of forward ranges.");
    }

    double[][] xTx;
    double[] xTy;

    typeof(X) xSaved;
    static if(arrayX) {
        xSaved = X.tempdup;
        foreach(ref elem; xSaved) {
            elem = elem.save;
        }
    } else {
        xSaved = saveAll(X).expand;
    }

    rangeMatrixMulTrans(xTy, xTx, Y.save, X);
    invert(xTx);
    double[] betas = new double[X.length];
    foreach(i; 0..betas.length) {
        betas[i] = 0;
        foreach(j; 0..betas.length) {
            betas[i] += xTx[i][j] * xTy[j];
        }
    }

    auto residuals = residuals(betas, Y, X);
    double S = 0;
    ulong n = 0;
    PearsonCor R2Calc;
    for(; !residuals.empty; residuals.popFront) {
        double residual = residuals.front;
        S += residual * residual;
        double Yfront = residuals.Y.front;
        double predicted = Yfront - residual;
        R2Calc.put(predicted, Yfront);
        n++;
    }
    immutable ulong df =  n - X.length;
    immutable double R2 = R2Calc.cor ^^ 2;
    immutable double adjustedR2 = 1.0L - (1.0L - R2) * ((n - 1.0L) / df);

    immutable double sigma2 = S / (n - X.length);

    double[] stdErr = new double[betas.length];
    foreach(i, ref elem; stdErr) {
        elem = sqrt( S * xTx[i][i] / df);
    }

    double[] lowerBound = new double[betas.length],
           upperBound = new double[betas.length],
           p = new double[betas.length];
    foreach(i, beta; betas) {
        try {
            p[i] = 2 * min(studentsTCDF(beta / stdErr[i], df),
                           studentsTCDFR(beta / stdErr[i], df));
        } catch(DstatsArgumentException) {
            // Leave it as a NaN.
        }

        try {
            double delta = invStudentsTCDF(0.5 * (1 - confLvl), df) *
                 stdErr[i];
            upperBound[i] = beta - delta;
            lowerBound[i] = beta + delta;
        } catch(DstatsArgumentException) {
            // Leave confidence bounds as NaNs.
        }
    }

    double F = (R2 / (X.length - 1)) / ((1 - R2) / (n - X.length));
    double overallP;
    try {
        overallP = fisherCDFR(F, X.length - 1, n - X.length);
    } catch(DstatsArgumentException) {
        // Leave it as a NaN.
    }

    return RegressRes(betas, stdErr, lowerBound, upperBound, p, R2,
        adjustedR2, sqrt(sigma2), overallP);
}

/**Convenience function that takes a forward range X and a forward range Y,
 * creates an array of PowMap structs for integer powers from 0 through N,
 * and calls linearRegressBeta.
 *
 * Returns:  An array of doubles.  The index of each element corresponds to
 * the exponent.  For example, the X<sup>2</sup> term will have an index of
 * 2.
 */
double[] polyFitBeta(T, U)(U Y, T X, uint N) {
    double[] dummy;
    return polyFitBetaBuf!(T, U)(dummy, Y, X, N);
}

/**Same as polyFitBeta, but allows the caller to provide an explicit buffer
 * to return the coefficients in.  If it's too short, a new one will be
 * allocated.  Otherwise, results will be returned in the user-provided buffer.
 */
double[] polyFitBetaBuf(T, U)(double[] buf, U Y, T X, uint N) {
    mixin(newFrame);
    auto pows = newStack!(PowMap!(uint, T))(N + 1);
    foreach(exponent; 0..N + 1) {
        pows[exponent] = powMap(X, exponent);
    }
    return linearRegressBetaBuf(buf, Y, pows);
}

/**Convenience function that takes a forward range X and a forward range Y,
 * creates an array of PowMap structs for integer powers 0 through N,
 * and calls linearRegress.
 *
 * Returns:  A PolyFitRes containing the array of PowMap structs created and
 * a RegressRes.  The PolyFitRes is alias this'd to the RegressRes.*/
PolyFitRes!(PowMap!(uint, T)[])
polyFit(T, U)(U Y, T X, uint N, double confInt = 0.95) {
    enforceConfidence(confInt);
    auto pows = new PowMap!(uint, T)[N + 1];
    foreach(exponent; 0..N + 1) {
        pows[exponent] = powMap(X, exponent);
    }
    alias PolyFitRes!(typeof(pows)) RT;
    RT ret;
    ret.X = pows;
    ret.regressRes = linearRegress(Y, pows, confInt);
    return ret;
}

version(unittest) {
    import std.stdio;
    void main(){}
}

unittest {
    // These are a bunch of values gleaned from various examples on the Web.
    double[] heights = [1.47,1.5,1.52,1.55,1.57,1.60,1.63,1.65,1.68,1.7,1.73,1.75,
        1.78,1.8,1.83];
    double[] weights = [52.21,53.12,54.48,55.84,57.2,58.57,59.93,61.29,63.11,64.47,
        66.28,68.1,69.92,72.19,74.46];
    float[] diseaseSev = [1.9,3.1,3.3,4.8,5.3,6.1,6.4,7.6,9.8,12.4];
    ubyte[] temperature = [2,1,5,5,20,20,23,10,30,25];

    // Values from R.
    auto res1 = polyFit(diseaseSev, temperature, 1);
    assert(approxEqual(res1.betas[0], 2.6623));
    assert(approxEqual(res1.betas[1], 0.2417));
    assert(approxEqual(res1.stdErr[0], 1.1008));
    assert(approxEqual(res1.stdErr[1], 0.0635));
    assert(approxEqual(res1.p[0], 0.0419));
    assert(approxEqual(res1.p[1], 0.0052));
    assert(approxEqual(res1.R2, 0.644));
    assert(approxEqual(res1.adjustedR2, 0.6001));
    assert(approxEqual(res1.residualError, 2.03));
    assert(approxEqual(res1.overallP, 0.00518));


    auto res2 = polyFit(weights, heights, 2);
    assert(approxEqual(res2.betas[0], 128.813));
    assert(approxEqual(res2.betas[1], -143.162));
    assert(approxEqual(res2.betas[2], 61.960));

    assert(approxEqual(res2.stdErr[0], 16.308));
    assert(approxEqual(res2.stdErr[1], 19.833));
    assert(approxEqual(res2.stdErr[2], 6.008));

    assert(approxEqual(res2.p[0], 4.28e-6));
    assert(approxEqual(res2.p[1], 1.06e-5));
    assert(approxEqual(res2.p[2], 2.57e-7));

    assert(approxEqual(res2.R2, 0.9989, 0.0001));
    assert(approxEqual(res2.adjustedR2, 0.9987, 0.0001));

    assert(approxEqual(res2.lowerBound[0], 92.9, 0.01));
    assert(approxEqual(res2.lowerBound[1], -186.8, 0.01));
    assert(approxEqual(res2.lowerBound[2], 48.7, 0.01));
    assert(approxEqual(res2.upperBound[0], 164.7, 0.01));
    assert(approxEqual(res2.upperBound[1], -99.5, 0.01));
    assert(approxEqual(res2.upperBound[2], 75.2, 0.01));

    auto res3 = linearRegress(weights, repeat(1), heights, map!"a * a"(heights));
    assert(res2.betas == res3.betas);

    double[2] beta1Buf;
    auto beta1 = linearRegressBetaBuf
        (beta1Buf[], diseaseSev, repeat(1), temperature);
    assert(beta1Buf.ptr == beta1.ptr);
    assert(beta1Buf[] == beta1[]);
    assert(beta1 == res1.betas);
    auto beta2 = polyFitBeta(weights, heights, 2);
    assert(beta2 == res2.betas);

    auto res4 = linearRegress(weights, repeat(1), heights);
    assert(approxEqual(res4.p, 3.604e-14));
    assert(approxEqual(res4.betas, [-39.062, 61.272]));
    assert(approxEqual(res4.p, [6.05e-9, 3.60e-14]));
    assert(approxEqual(res4.R2, 0.9892));
    assert(approxEqual(res4.adjustedR2, 0.9884));
    assert(approxEqual(res4.residualError, 0.7591));
    assert(approxEqual(res4.lowerBound, [-45.40912, 57.43554]));
    assert(approxEqual(res4.upperBound, [-32.71479, 65.10883]));

    // Test residuals.
    assert(approxEqual(residuals(res4.betas, weights, repeat(1), heights),
        [1.20184170, 0.27367611,  0.40823237, -0.06993322,  0.06462305,
         -0.40354255, -0.88170814,  -0.74715188, -0.76531747, -0.63076120,
         -0.65892680, -0.06437053, -0.08253613,  0.96202014,  1.39385455]));
}

/**Computes a logistic regression using a maximum likelihood estimator
 * and returns the beta coefficients.  This is a generalized linear model with
 * the link function f(XB) = 1 / (1 + exp(XB)). This is generally used to model
 * the probability that a binary Y variable is 1 given a set of X variables.
 *
 * For the purpose of this function, Y variables are interpreted as Booleans,
 * regardless of their type.  X may be either a range of ranges or a tuple of
 * ranges.  However, note that unlike in linearRegress, they are copied to an
 * array if they are not random access ranges.  Note that each value is accessed
 * several times, so if your range is a map to something expensive, you may
 * want to evaluate it eagerly.
 *
 * Also note that, as in linearRegress, repeat(1) can be used for the intercept
 * term.
 *
 * Returns:  The beta coefficients for the regression model.
 *
 * TODO:  Add hypothesis testing stuff and generalize to a parametrizable
 *        generalized linear model function.
 *
 * References:
 * http://en.wikipedia.org/wiki/Logistic_regression
 * http://socserv.mcmaster.ca/jfox/Courses/UCLA/logistic-regression-notes.pdf
 */
double[] logisticRegressBeta(T, U...)(T yIn, U xIn) {
    mixin(newFrame);

    static assert(!isInfinite!T, "Can't do regression with infinite # of Y's.");
    static if(isRandomAccessRange!T) {
        alias yIn y;
    } else {
        auto y = toBools(yIn);
    }

    static if(U.length == 1 && isRoR!U) {
        static if(isForwardRange!U) {
            auto x = toRandomAccessRoR(y.length, xIn);
        } else {
            auto x = toRandomAccessRoR(y.length, tempdup(xIn));
        }
    } else {
        auto x = toRandomAccessTuple(xIn).expand;
    }

    auto beta = new double[x.length];
    beta[] = 0;

    doMLE(beta, y, x);

    return beta;
}

unittest {
    // Values from R.
    alias approxEqual ae;  // Save typing.

    // Start with the basics, with X as a ror.
    auto y1 =  [1,   0, 0, 0, 1, 0, 0];
    auto x1 = [[1.0, 1 ,1 ,1 ,1 ,1 ,1],
              [8.0, 6, 7, 5, 3, 0, 9]];
    auto res1 = logisticRegressBeta(y1, x1);
    assert(ae(res1[0], -0.98273));
    assert(ae(res1[1], 0.01219));

    // Use tuple.
    auto y2   = [1,0,1,1,0,1,0,0,0,1,0,1];
    auto x2_1 = [3,1,4,1,5,9,2,6,5,3,5,8];
    auto x2_2 = [2,7,1,8,2,8,1,8,2,8,4,5];
    auto res2 = logisticRegressBeta(y2, repeat(1), x2_1, x2_2);
    assert(ae(res2[0], -1.1875));
    assert(ae(res2[1], 0.1021));
    assert(ae(res2[2], 0.1603));

    auto x2Intercept = [1,1,1,1,1,1,1,1,1,1,1,1];
    auto res2a = logisticRegressBeta(y2,
        filter!"a.length"([x2Intercept, x2_1, x2_2]));
    assert(ae(res2a, res2));

    // Use a huge range of values to test numerical stability.

    // The filter is to make y3 a non-random access range.
    auto y3 = filter!"a < 2"([1,1,1,1,0,0,0,0]);
    auto x3_1 = filter!"a > 0"([1, 1e10, 2, 2e10, 3, 3e15, 4, 4e7]);
    auto x3_2 = [1e8, 1e6, 1e7, 1e5, 1e3, 1e0, 1e9, 1e11];
    auto x3_3 = [-5e12, 5e2, 6e5, 4e3, -999999, -666, -3e10, -2e10];
    auto res3 = logisticRegressBeta(y3, repeat(1), x3_1, x3_2, x3_3);
    assert(ae(res3[0], 1.115e0));
    assert(ae(res3[1], -4.674e-15));
    assert(ae(res3[2], -7.026e-9));
    assert(ae(res3[3], -2.109e-12));

    // Test with a just plain huge dataset that R chokes for several minutes
    // on.  If you think this unittest is slow, try getting the reference
    // values from R.
    auto y4 = chain(
                take(cycle([0,0,0,0,1]), 500_000),
                take(cycle([1,1,1,1,0]), 500_000));
    auto x4_1 = iota(0, 1_000_000);
    auto x4_2 = map!exp(map!"a / 1_000_000.0"(x4_1));
    auto x4_3 = take(cycle([1,2,3,4,5]), 1_000_000);
    auto x4_4 = take(cycle([8,6,7,5,3,0,9]), 1_000_000);
    auto res4 = logisticRegressBeta(y4, repeat(1), x4_1, x4_2, x4_3, x4_4);
    assert(ae(res4[0], -1.574));
    assert(ae(res4[1], 5.625e-6));
    assert(ae(res4[2], -7.282e-1));
    assert(ae(res4[3], -4.381e-6));
    assert(ae(res4[4], -8.343e-6));
}

/// The inverse logit function used in logistic regression.
double inverseLogit(double xb) pure nothrow {
    return 1.0 / (1 + exp(-xb));
}

private:
double doMLE(T, U...)(double[] beta, T y, U xIn) {
    // This big, disgusting function uses the Newton-Raphson method as outlined
    // in http://socserv.mcmaster.ca/jfox/Courses/UCLA/logistic-regression-notes.pdf
    //
    // The matrix operations are kind of obfuscated because they're written
    // using very low-level primitives and with as little temp space as
    // possible used.
    static if(isRoR!(U[0]) && U.length == 1) {
        alias xIn[0] x;
    } else {
        alias xIn x;
    }

    mixin(newFrame);
    immutable N = y.length;

    auto ps = newStack!double(y.length);

    double[] xRow = newStack!double(beta.length);
    void evalPs() {
        foreach(i; 0..N) {

            double prodSum = 0;
            foreach(j, col; x) {
                prodSum += col[i] * beta[j];
            }

            ps[i] = inverseLogit(prodSum);
            assert(ps[i] >= 0, text(ps[i]));
            assert(ps[i] <= 1, text(ps[i]));
        }
    }

    double logLikelihood() {
        double sum = 0;
        size_t i = 0;
        foreach(yVal; y) {
            scope(exit) i++;
            if(yVal) {
                sum -= 2 * log(ps[i]);
            } else {
                sum -= 2 * log(1 - ps[i]);
            }
        }
        return sum;
    }


    enum eps = 1e-6;
    enum maxIter = 1000;

    auto oldLikelihood = double.infinity;

    auto mat = newStack!(double[])(beta.length);
    foreach(ref row; mat) {
        // The *2 is for the augmentations scratch space for inversion.
        row = newStack!double(beta.length * 2);
    }

    foreach(iter; 0..maxIter) {
        evalPs();
        immutable lh = logLikelihood();

        if(oldLikelihood - lh < eps || isNaN(lh)) {
            return lh;
        }
        oldLikelihood = lh;

        foreach(i; 0..beta.length) {
            mat[i] = mat[i][0..beta.length];
            mat[i][] = 0;
        }

        // Calculate X' * W * X in the notation of our reference.  Since
        // V is a diagonal matrix of ps[] * (1.0 - ps[]), we only have one
        // dimension representing it.
        foreach(i, dummy; x) foreach(j, dummy2; x) {
            foreach(k; 0..ps.length) {
                mat[i][j] += (ps[k] * (1 - ps[k])) * x[i][k] * x[j][k];
            }
        }

        foreach(i; 0..mat.length) {
            // We allocated this augmentation area, but it got sliced away by
            // invert().  Put it back.
            mat[i] = mat[i].ptr[0..beta.length * 2];
            mat[i][beta.length..$] = 0;
        }

        // Invert the intermediate matrix.
        invert(mat);

        // Now, multiply the resulting matrix by X' * (y - p).
        foreach(betaIndex, ref b; beta) {
            double diff = 0;

            foreach(pIndex, p; ps) {
                immutable pDiff = (y[pIndex] != 0) ? (1.0 - p) : -1.0 * p;
                double sum = 0;
                foreach(betaIndex2, dummy; x) {
                    diff += mat[betaIndex][betaIndex2] *
                            x[betaIndex2][pIndex] * pDiff;
                }
            }

            b += diff;
        }

        debug(print) writeln("Iter:  ", iter);
    }

    return logLikelihood();
}

template isRoR(T) {
    static if(!isInputRange!T) {
        enum isRoR = false;
    } else {
        enum isRoR = isInputRange!(typeof(T.init.front()));
    }
}

template isFloatMat(T) {
    static if(is(T : const(float[][])) ||
        is(T : const(real[][])) || is(T : const(double[][]))) {
        enum isFloatMat = true;
    } else {
        enum isFloatMat = false;
    }
}

template NonRandomToArray(T) {
    static if(isRandomAccessRange!T) {
        alias T NonRandomToArray;
    } else {
        alias Unqual!(ElementType!(T))[] NonRandomToArray;
    }
}

bool[] toBools(R)(R range) {
    return tempdup(map!"(a) ? true : false"(range));
}

auto toRandomAccessRoR(T)(size_t len, T ror) {
    static assert(isRoR!T);
    alias ElementType!T E;
    static if(isRandomAccessRange!T && isRandomAccessRange!E) {
        return ror;
    } else static if(!isRandomAccessRange!T && isRandomAccessRange!E) {
        return tempdup(ror);
    } else {
        auto ret = newStack!(E[])(walkLength(ror.save));

        foreach(ref col; ret) {
            scope(exit) ror.popFront();
            col = newStack!E(len);

            size_t i;
            foreach(elem; ror.front) {
                col[i++] = elem;
            }
        }

        return ret;
    }
}

auto toRandomAccessTuple(T...)(T input) {
    Tuple!(staticMap!(NonRandomToArray, T)) ret;

    foreach(ti, range; input) {
        static if(isRandomAccessRange!(typeof(range))) {
            ret.field[ti] = range;
        } else {
            ret.field[ti] = tempdup(range);
        }
    }

    return ret;
}
