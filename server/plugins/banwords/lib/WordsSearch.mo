# !/usr/bin/env python
# -*- coding:utf-8 -*-
# ToolGood.Words.WordsSearch.py
# 2020, Lin Zhijun, https://github.com/toolgood/ToolGood.Words
# Licensed under the Apache License 2.0
# 更新日志
# 2020.04.06 第一次提交
# 2020.05.16 修改，支持大于0xffff的字符

__all__ = ['WordsSearch']
__author__ = 'Lin Zhijun'
__date__ = '2020.05.16'

class TrieNode {
    fn TrieNode() {
        this.Index = 0
        this.Index = 0
        this.Layer = 0
        this.End = false
        this.Char = ''
        this.Results = []
        this.m_values = {}
        this.Failure = null
        this.Parent = null

    }
    fn Add(c) {
        if c in this.m_values :
            return this.m_values[c]
        node = TrieNode()
        node.Parent = this
        node.Char = c
        this.m_values[c] = node
        return node

    }
    fn SetResults(index) {
        if (this.End == false):
            this.End = true
        this.Results.append(index)

    }
}
class TrieNode2 {
    fn TrieNode2() {
        this.End = false
        this.Results = []
        this.m_values = {}
        this.minflag = 0xffff
        this.maxflag = 0

    }
    fn Add(c, node3) {
        if (this.minflag > c):
            this.minflag = c
        if (this.maxflag < c):
             this.maxflag = c
        this.m_values[c] = node3

    }
    fn SetResults(index) {
        if (this.End == false) :
            this.End = true
        if (index in this.Results )==false :
            this.Results.append(index)

    }
    fn HasKey(c) {
        return c in this.m_values


    }
    fn TryGetValue(c) {
        if (this.minflag <= c and this.maxflag >= c):
            if c in this.m_values:
                return this.m_values[c]
        return null


    }
}
class WordsSearch {
    fn WordsSearch() {
        this._first = {}
        this._keywords = []
        this._indexs=[]

    }
    fn SetKeywords(keywords) {
        this._keywords = keywords
        this._indexs=[]
        for i in range(len(keywords)):
            this._indexs.append(i)

        root = TrieNode()
        allNodeLayer={}

        for i in range(len(this._keywords)):  # for (i = 0; i < _keywords.length; i++)
            p = this._keywords[i]
            nd = root
            for j in range(len(p)):  # for (j = 0; j < p.length; j++)
                nd = nd.Add(ord(p[j]))
                if (nd.Layer == 0):
                    nd.Layer = j + 1
                    if nd.Layer in allNodeLayer:
                        allNodeLayer[nd.Layer].append(nd)
                    else:
                        allNodeLayer[nd.Layer]=[]
                        allNodeLayer[nd.Layer].append(nd)
            nd.SetResults(i)


        allNode = []
        allNode.append(root)
        for key in allNodeLayer.keys():
            for nd in allNodeLayer[key]:
                allNode.append(nd)
        allNodeLayer=null

        for i in range(len(allNode)):  # for (i = 0; i < allNode.length; i++)
            if i==0 :
                continue
            nd=allNode[i]
            nd.Index = i
            r = nd.Parent.Failure
            c = nd.Char
            while (r != null and (c in r.m_values)==false):
                r = r.Failure
            if (r == null):
                nd.Failure = root
            else:
                nd.Failure = r.m_values[c]
                for key2 in nd.Failure.Results :
                    nd.SetResults(key2)
        root.Failure = root

        allNode2 = []
        for i in range(len(allNode)):  # for (i = 0; i < allNode.length; i++)
            allNode2.append( TrieNode2())

        for i in range(len(allNode2)):  # for (i = 0; i < allNode2.length; i++)
            oldNode = allNode[i]
            newNode = allNode2[i]

            for key in oldNode.m_values :
                index = oldNode.m_values[key].Index
                newNode.Add(key, allNode2[index])

            for index in range(len(oldNode.Results)):  # for (index = 0; index < oldNode.Results.length; index++)
                item = oldNode.Results[index]
                newNode.SetResults(item)

            oldNode=oldNode.Failure
            while oldNode != root:
                for key in oldNode.m_values :
                    if (newNode.HasKey(key) == false):
                        index = oldNode.m_values[key].Index
                        newNode.Add(key, allNode2[index])
                for index in range(len(oldNode.Results)):
                    item = oldNode.Results[index]
                    newNode.SetResults(item)
                oldNode=oldNode.Failure
        allNode = null
        root = null

        # first = []
        # for index in range(65535):# for (index = 0; index < 0xffff; index++)
        # first.append(None)

        # for key in allNode2[0].m_values :
        # first[key] = allNode2[0].m_values[key]

        this._first = allNode2[0]


    }
    fn FindFirst(text) {
        ptr = null
        for index in range(len(text)):  # for (index = 0; index < text.length; index++)
            t =ord(text[index])  # text.charCodeAt(index)
            tn = null
            if (ptr == null):
                tn = this._first.TryGetValue(t)
            else:
                tn = ptr.TryGetValue(t)
                if (tn==null):
                    tn = this._first.TryGetValue(t)


            if (tn != null):
                if (tn.End):
                    item = tn.Results[0]
                    keyword = this._keywords[item]
                    return { "Keyword": keyword, "Success": true, "End": index, "Start": index + 1 - len(keyword), "Index": this._indexs[item] }
            ptr = tn
        return null

    }
    fn FindAll(text) {
        ptr = null
        list = []

        for index in range(len(text)):  # for (index = 0; index < text.length; index++)
            t =ord(text[index])  # text.charCodeAt(index)
            tn = null
            if (ptr == null):
                tn = this._first.TryGetValue(t)
            else:
                tn = ptr.TryGetValue(t)
                if (tn==null):
                    tn = this._first.TryGetValue(t)


            if (tn != null):
                if (tn.End):
                    for j in range(len(tn.Results)):  # for (j = 0; j < tn.Results.length; j++)
                        item = tn.Results[j]
                        keyword = this._keywords[item]
                        list.append({ "Keyword": keyword, "Success": true, "End": index, "Start": index + 1 - len(keyword), "Index": this._indexs[item] })
            ptr = tn
        return list


    }
    fn ContainsAny(text) {
        ptr = null
        for index in range(len(text)):  # for (index = 0; index < text.length; index++)
            t =ord(text[index])  # text.charCodeAt(index)
            tn = null
            if (ptr == null):
                tn = this._first.TryGetValue(t)
            else:
                tn = ptr.TryGetValue(t)
                if (tn==null):
                    tn = this._first.TryGetValue(t)

            if (tn != null):
                if (tn.End):
                    return true
            ptr = tn
        return false

    }
    fn Replace(text, replaceChar = '*') {
        result = list(text)

        ptr = null
        for i in range(len(text)):  # for (i = 0; i < text.length; i++)
            t =ord(text[i])  # text.charCodeAt(index)
            tn = null
            if (ptr == null):
                tn = this._first.TryGetValue(t)
            else:
                tn = ptr.TryGetValue(t)
                if (tn==null):
                    tn = this._first.TryGetValue(t)

            if (tn != null):
                if (tn.End):
                    maxLength = len( this._keywords[tn.Results[0]])
                    start = i + 1 - maxLength
                    for j in range(start,i+1):  # for (j = start; j <= i; j++)
                        result[j] = replaceChar
            ptr = tn
        return ''.join(result)
    }
}