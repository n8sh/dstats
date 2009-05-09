/**A module for performing linear regression.  This module has an unusual
 * interface, as it is range-based instead of matrix based. Values for
 * independent variables are provided as either a tuple or an array of ranges.
 * This means that one can use, for example, map, to fit high order models and
 * lazily evaluate certain values.  (For details, see examples below.)*/
module dstats.regress;

import std.math, std.algorithm, std.traits, std.array,
    dstats.alloc, std.range, std.conv, dstats.distrib, dstats.cor, dstats.base;

///
struct PowMap(ExpType, T)
if(isForwardRange!(T)) {
    T range;
    ExpType exponent;
    real cache;

    this(T range, ExpType exponent) {
        this.range = range;
        this.exponent = exponent;
        cache = pow(cast(real) range.front, exponent);
    }

    real front() const pure nothrow {
        return cache;
    }

    void popFront() {
        range.popFront;
        if(!range.empty) {
            cache = pow(cast(real) range.front, exponent);
        }
    }

    bool empty() {
        return range.empty;
    }
}

/**Maps a forward range to a power determined at runtime.  ExpType is the type
 * of the exponent.  Using an int is faster than using a real, but obviously
 * less flexible.*/
PowMap!(ExpType, T) powMap(ExpType, T)(T range, ExpType exponent) {
    alias PowMap!(ExpType, T) RT;
    return RT(range, exponent);
}

// Very ad-hoc, does a bunch of matrix ops.  Written specifically to be
// efficient in the context used here.
private void rangeMatrixMulTrans(U, T...)(out real[] xTy, out real[][] xTx, U vec, T matIn) {
    static if(isArray!(T[0]) && isInputRange!(typeof(matIn[0][0])) && matIn.length == 1) {
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

    xTy = newStack!real(mat.length);
    xTy[] = 0;

    xTx = newStack!(real[])(mat.length);
    foreach(ref elem; xTx) {
        elem = newStack!real(mat.length * 2);
    }

    foreach(row; xTx) {
        row[] = 0;
    }

    while(!someEmpty) {
        foreach(i, elem1; mat) {
            real e1Front = cast(real) elem1.front;
            xTy[i] += cast(real) elem1.front * cast(real) vec.front;
            xTx[i][i] += e1Front * e1Front;
            foreach(jMinusI, elem2; mat[i + 1..$]) {
                immutable j = i + 1 + jMinusI;
                real num = e1Front * cast(real) elem2.front;
                xTx[i][j] += num;
                xTx[j][i] += num;
            }
        }
        popAll;
    }
}

// Uses Gauss-Jordan elim. w/ row pivoting.  Not that efficient, but for the ad-hoc purposes
// it was meant for, it should be good enough.
void invert(ref real[][] mat) {
    // Normalize, augment w/ identity.  The matrix is already the right size
    // from rangeMatrixMulTrans.
    foreach(i, row; mat) {
        real absMax = 1.0L / reduce!(max)(map!("a > 0 ? a : -a")(row[0..mat.length]));
        row[0..mat.length] *= absMax;
        row[i + mat.length] = absMax;
    }

    foreach(col; 0..mat.length) {
        size_t bestRow;
        real biggest = 0;
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
            real ratio = mat[row][col] / mat[col][col];
            foreach(i, ref elem; mat[row]) {
                elem -= mat[col][i] * ratio;
            }
        }
    }


    foreach(i; 0..mat.length) {
        real diagVal = mat[i][i];
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
    real[] betas;

    /**The standard error terms of the X ranges passed in.*/
    real[] stdErr;

    /**The lower confidence bounds of the beta terms, at the confidence level
     * specificied.  (Default 0.95).*/
    real[] lowerBound;

    /**The upper confidence bounds of the beta terms, at the confidence level
     * specificied.  (Default 0.95).*/
    real[] upperBound;

    /**The P-value for the alternative that the corresponding beta value is
     * different from zero against the null that it is equal to zero.*/
    real[] p;

    /**The coefficient of determination.*/
    real R2;

    /**The root mean square of the residuals.*/
    real residualError;

    /**The P-value for the model as a whole.  Based on an F-statistic.  The
     * null here is that the model has no predictive value, the alternative
     * is that it does.*/
    real overallP;

    // Just used internally.
    private static string arrStr(T)(T arr) {
        return text(arr)[1..$ - 1];
    }

    /**Print out the results in the default format.*/
    string toString() {
        return "Betas:  " ~ arrStr(betas) ~ "\nLower Conf. Int.:  " ~
            arrStr(lowerBound) ~ "\nUpper Conf. Int.:  " ~ arrStr(upperBound) ~
            "\nStd. Err:  " ~ arrStr(stdErr) ~ "\nP Values:  " ~ arrStr(p) ~
            "\nR^2:  " ~ text(R2) ~ "\nStd. Residual Error:  " ~ text(residualError)
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

// Used internally.  May eventually become public, documented.
private struct Residuals(U, T...) {
    static if(T.length == 1 && isForwardRange!(typeof(T[0].front()))) {
        alias T[0] R;
    } else {
        alias T R;
    }

    U Y;
    R X;
    real[] betas;
    real residual;
    bool _empty;

    void nextResidual() {
        real sum = 0;
        size_t i = 0;
        foreach(elem; X) {
            sum += cast(real) elem.front * betas[i];
            i++;
        }
        residual = sum - Y.front;
    }

    this(real[] betas, U Y, R X) {
        this.X = X;
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

    real front() const pure nothrow {
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

    bool empty() const pure nothrow {
        return _empty;
    }
}

private Residuals!(U, T) residuals(U, T...)(real[] betas, U Y, T X) {
    alias Residuals!(U, T) RT;
    return RT(betas, Y, X);
}

/**Perform a linear regression and return just the beta values.  The advantages
 * to just returning the beta values are that it's faster and that each range
 * needsd to be iterated over only once, and thus can be just an input range.
 * The beta values are returned such that the smallest index corresponds to
 * the leftmost element of X.  X can be either a tuple or an array of input
 * ranges.  Y must be an input range.
 *
 * Notes:  The X ranges are traversed in locksep, but the traversal is stopped
 * at the end of the shortest one.  Therefore, using infinite ranges is safe.
 * For example, using repeat(1) to get an intercept term works.
 *
 * Examples:
 * ---
 * int[] nBeers = [8,6,7,5,3,0,9];
 * int[] nCoffees = [3,6,2,4,3,6,8];
 * int[] musicVolume = [3,1,4,1,5,9,2];
 * int[] programmingSkill = [2,7,1,8,2,8,1];
 * real[] betas = linearRegressBeta(programmingSkill, repeat(1), nBeers, nCoffees,
 *     musicVolume, map!"a * a"(musicVolume));
 * ---
 */
real[] linearRegressBeta(U, T...)(U Y, T XIn)
if(allSatisfy!(isInputRange, T) && realInput!(U)) {
    mixin(newFrame);
    static if(isArray!(T[0]) && isInputRange!(typeof(XIn[0][0])) &&
        T.length == 1) {
        alias typeof(XIn[0].front) E;
        typeof(XIn[0]) X = tempdup(cast(E[]) XIn[0]);
    } else {
        alias XIn X;
    }

    real[][] xTx;
    real[] xTy;
    rangeMatrixMulTrans(xTy, xTx, Y, X);
    invert(xTx);
    real[] ret = new real[X.length];
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
 * 2.  If you have a large amount of data and you're mapping it to some
 *     expensive function, you may want to do this eagerly instead of lazily.
 *
 * Notes:  The X ranges are traversed in locksep, but the traversal is stopped
 * at the end of the shortest one.  Therefore, using infinite ranges is safe.
 * For example, using repeat(1) to get an intercept term works.
 *
 * Examples:
 * ---
 * int[] nBeers = [8,6,7,5,3,0,9];
 * int[] nCoffees = [3,6,2,4,3,6,8];
 * int[] musicVolume = [3,1,4,1,5,9,2];
 * int[] programmingSkill = [2,7,1,8,2,8,1];
 *
 * // Using default confidence interval:
 * auto results = linearRegressBeta(programmingSkill, repeat(1), nBeers, nCoffees,
 *     musicVolume, map!"a * a"(musicVolume));
 *
 * // Using user-specified confidence interval:
 * auto results = linearRegressBeta(programmingSkill, repeat(1), nBeers, nCoffees,
 *     musicVolume, map!"a * a"(musicVolume), 0.8675309);
 * ---
 */
RegressRes linearRegress(U, TC...)(U Y, TC input) {
    static if(is(TC[$ - 1] : real)) {
        real confLvl = input[$ - 1];
        alias TC[0..$ - 1] T;
        alias input[0..$ - 1] XIn;
    } else {
        real confLvl = 0.95; // Default;
        alias TC T;
        alias input XIn;
    }

    mixin(newFrame);
    static if(isArray!(T[0]) && isForwardRange!(typeof(XIn[0].front())) &&
        T.length == 1) {
        alias typeof(XIn[0].front) E;
        typeof(XIn[0]) X = tempdup(cast(E[]) XIn[0]);
    } else {
        alias XIn X;
    }

    real[][] xTx;
    real[] xTy;
    rangeMatrixMulTrans(xTy, xTx, Y, X);
    invert(xTx);
    real[] betas = new real[X.length];
    foreach(i; 0..betas.length) {
        betas[i] = 0;
        foreach(j; 0..betas.length) {
            betas[i] += xTx[i][j] * xTy[j];
        }
    }

    alias Residuals!(U, T) RT;
    auto residuals = RT(betas, Y, X);
    real S = 0;
    uint n = 0;
    OnlinePcor R2Calc;
    for(; !residuals.empty; residuals.popFront) {
        real residual = residuals.front;
        S += residual * residual;
        real Yfront = residuals.Y.front();
        real predicted = residual + Yfront;
        R2Calc.put(predicted, Yfront);
        n++;
    }
    uint df =  n - X.length;
    real R2 = R2Calc.cor();
    R2 *= R2;
    real sigma2 = S / (n - X.length);

    real[] stdErr = new real[betas.length];
    foreach(i, ref elem; stdErr) {
        elem = sqrt( S * xTx[i][i] / df);
    }

    real[] lowerBound = new real[betas.length],
           upperBound = new real[betas.length],
           p = new real[betas.length];
    foreach(i, beta; betas) {
        p[i] = 2 * min(studentsTCDF(beta / stdErr[i], df),
                       studentsTCDFR(beta / stdErr[i], df));
        real delta = invStudentsTCDF(0.5 * (1 - confLvl), df) *
             stdErr[i];
        upperBound[i] = beta - delta;
        lowerBound[i] = beta + delta;
    }

    real F = (R2 / (X.length - 1)) / ((1 - R2) / (n - X.length));
    real overallP = fisherCDFR(F, X.length - 1, n - X.length);

    return RegressRes(betas, stdErr, lowerBound, upperBound, p, R2, sqrt(sigma2), overallP);
}

/**Convenience function that takes a forward range X and a forward range Y,
 * creates an array of PowMap structs for integer powers from 0 through N,
 * and calls linearRegressBeta.
 *
 * Returns:  An array of reals.  The index of each element corresponds to
 * the exponent.  For example, the X<sup>2</sup> term will have an index of
 * 2.
 */
real[] polyFitBeta(T, U)(U Y, T X, uint N) {
    mixin(newFrame);
    auto pows = newStack!(PowMap!(uint, T))(N + 1);
    foreach(exponent; 0..N + 1) {
        pows[exponent] = powMap(X, exponent);
    }
    return linearRegressBeta(Y, pows);
}

/**Convenience function that takes a forward range X and a forward range Y,
 * creates an array of PowMap structs for integer powers 0 through N,
 * and calls linearRegress.
 *
 * Returns:  A PolyFitRes containing the array of PowMap structs created and
 * a RegressRes.  The PolyFitRes is alias this'd to the RegressRes.*/
PolyFitRes!(PowMap!(uint, T)[]) polyFit(T, U)(U Y, T X, uint N, real confInt = 0.95) {
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
    real[] heights = [1.47,1.5,1.52,1.55,1.57,1.60,1.63,1.65,1.68,1.7,1.73,1.75,
        1.78,1.8,1.83];
    real[] weights = [52.21,53.12,54.48,55.84,57.2,58.57,59.93,61.29,63.11,64.47,
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
    assert(approxEqual(res1.residualError, 2.03));
    assert(approxEqual(res1.overallP, 0.00518));

    // Values from Wikipedia.  Note that the confidence intervals come out
    // slightly different than what Wikipedia gets.  This is because different
    // sources disagree on how many degrees of freedom to use.  For reasonably
    // large sample sizes this is of little consequence anyhow, since it only
    auto res2 = polyFit(weights, heights, 2);
    assert(approxEqual(res2.betas[0], 129));
    assert(approxEqual(res2.betas[1], -143));
    assert(approxEqual(res2.betas[2], 62));
    assert(approxEqual(round(res2.stdErr[0]), 16));
    assert(approxEqual(round(res2.stdErr[1]), 20));
    assert(approxEqual(round(res2.stdErr[2]), 6));
    assert(approxEqual(res2.lowerBound[0], 92.9, 0.01));
    assert(approxEqual(res2.lowerBound[1], -186.8, 0.01));
    assert(approxEqual(res2.lowerBound[2], 48.7, 0.01));
    assert(approxEqual(res2.upperBound[0], 164.7, 0.01));
    assert(approxEqual(res2.upperBound[1], -99.5, 0.01));
    assert(approxEqual(res2.upperBound[2], 75.2, 0.01));
    writeln("Passed regression unittest.");
}
